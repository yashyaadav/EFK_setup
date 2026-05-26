#!/usr/bin/env bash
# End-to-end verification that the EFK stack is healthy and logs flow.
# Run after `make up`. Prints PASS/FAIL per step; exits non-zero on any
# failure. Safe to re-run; cleans up the test pod it deploys.

set -uo pipefail

NS="${NS:-logging}"
ES_POD="es-cluster-0"
PASS=0; FAIL=0

pass() { echo "  PASS  $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }
step() { echo; echo "▶ $1"; }

# Resolve elastic password from the in-cluster Secret
ES_PW="$(kubectl -n "${NS}" get secret elastic-credentials \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
if [[ -z "${ES_PW}" ]]; then
  echo "Could not read elastic-credentials/password Secret. Run \`make secrets\` first."
  exit 1
fi

es_curl() {
  kubectl -n "${NS}" exec "${ES_POD}" -c elasticsearch -- \
    curl -fsS -u "elastic:${ES_PW}" \
    --cacert /usr/share/elasticsearch/config/certs/ca.crt \
    "https://localhost:9200$1"
}

step "1. All EFK pods Ready"
if kubectl -n "${NS}" wait --for=condition=ready pod \
     -l app.kubernetes.io/part-of=efk --timeout=300s >/dev/null 2>&1; then
  pass "pods ready in namespace ${NS}"
else
  fail "pods not Ready within 300s"
  kubectl -n "${NS}" get pods
fi

step "2. Elasticsearch cluster health"
HEALTH="$(es_curl '/_cluster/health' 2>/dev/null || true)"
STATUS="$(echo "${HEALTH}" | grep -oE '"status":"[a-z]+"' | head -1 | cut -d'"' -f4)"
case "${STATUS}" in
  green|yellow) pass "cluster status: ${STATUS}" ;;
  *)            fail "cluster status: ${STATUS:-unreachable}" ; echo "${HEALTH}" ;;
esac

step "3. Fluentd is shipping (logstash-* index exists)"
for i in 1 2 3 4 5 6; do
  CAT="$(es_curl '/_cat/indices/logstash-*?h=index,docs.count' 2>/dev/null || true)"
  if echo "${CAT}" | grep -qE 'logstash-[0-9]+'; then
    pass "indices: $(echo "${CAT}" | head -3 | tr '\n' ';')"
    break
  fi
  [[ $i -eq 6 ]] && fail "no logstash-* indices after 60s" || sleep 10
done

step "4. Fluentd pod logs clean (no fatal errors)"
ERRS="$(kubectl -n "${NS}" logs -l app.kubernetes.io/name=fluentd --tail=200 2>/dev/null \
  | grep -iE '\b(error|fatal)\b' \
  | grep -ivE 'expected pattern|will retry|connection refused' || true)"
if [[ -z "${ERRS}" ]]; then
  pass "no unexpected errors in Fluentd logs"
else
  fail "Fluentd logs show errors:"
  echo "${ERRS}" | head -5
fi

step "5. Kibana /api/status reports available"
PF_LOG="$(mktemp)"
kubectl -n "${NS}" port-forward svc/kibana 5601:5601 >"${PF_LOG}" 2>&1 &
PF_PID=$!
trap "kill ${PF_PID} 2>/dev/null || true" EXIT
sleep 3
LEVEL="$(curl -fsS http://localhost:5601/api/status 2>/dev/null \
  | grep -oE '"level":"[a-z]+"' | head -1 | cut -d'"' -f4)"
if [[ "${LEVEL}" == "available" ]]; then
  pass "Kibana status: available"
else
  fail "Kibana status: ${LEVEL:-unreachable}"
fi
kill ${PF_PID} 2>/dev/null || true
trap - EXIT

step "6. End-to-end: deploy nginx, see its logs in Kibana index"
kubectl run smoke-nginx --image=nginx --restart=Never -n default >/dev/null 2>&1 || true
kubectl wait --for=condition=ready pod/smoke-nginx -n default --timeout=60s >/dev/null 2>&1 || true
echo "  waiting 60s for log to flow…"
sleep 60
HITS="$(es_curl '/logstash-*/_search?q=kubernetes.pod_name:smoke-nginx&size=0' 2>/dev/null \
  | grep -oE '"total":\{"value":[0-9]+' | head -1 | grep -oE '[0-9]+$')"
if [[ "${HITS:-0}" -gt 0 ]]; then
  pass "found ${HITS} log doc(s) for smoke-nginx"
else
  fail "no logs found for smoke-nginx"
fi
kubectl delete pod smoke-nginx -n default --wait=false >/dev/null 2>&1 || true

step "7. RBAC scope: fluentd SA can list pods but not delete"
if kubectl auth can-i list pods --as=system:serviceaccount:"${NS}":fluentd -A >/dev/null 2>&1; then
  pass "fluentd SA can list pods cluster-wide"
else
  fail "fluentd SA cannot list pods (RBAC misconfigured?)"
fi
if kubectl auth can-i delete pods --as=system:serviceaccount:"${NS}":fluentd -A >/dev/null 2>&1; then
  fail "fluentd SA can DELETE pods (over-permissioned)"
else
  pass "fluentd SA cannot delete pods (least privilege OK)"
fi

echo
echo "── summary ── ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
