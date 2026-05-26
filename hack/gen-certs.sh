#!/usr/bin/env bash
# Generate a self-signed CA and a node certificate keystore for Elasticsearch.
# Idempotent: skips work if certs/elastic-certificates.p12 already exists.
# Outputs (all gitignored):
#   certs/ca.crt       — CA cert, mounted into Kibana + Fluentd (es-ca Secret)
#   certs/ca.key       — CA private key (kept local, not deployed)
#   certs/elastic-certificates.p12 — node keystore (es-tls Secret)
#
# Requires: docker. No need to install elasticsearch-certutil locally.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CERT_DIR="${ROOT_DIR}/certs"
ES_IMAGE="docker.elastic.co/elasticsearch/elasticsearch:7.14.0"

mkdir -p "${CERT_DIR}"

if [[ -f "${CERT_DIR}/elastic-certificates.p12" && -f "${CERT_DIR}/ca.crt" ]]; then
  echo "certs already exist in ${CERT_DIR}; skipping. (rm them to regenerate.)"
  exit 0
fi

echo "Generating CA + node certificate via elasticsearch-certutil…"

# elasticsearch-certutil writes into the container's working dir. We mount
# certs/ as /certs and run as the elasticsearch user (uid 1000) so output
# files are owned by the invoking user on the host.
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

# Work around Docker Desktop credsStore pointing at a missing helper. We're
# only pulling a public image, so a clean DOCKER_CONFIG with no credsStore
# is safe and avoids `exec: "docker-credential-desktop": executable file
# not found` on hosts where the CLI is installed without Docker Desktop.
TMP_DOCKER_CONFIG="$(mktemp -d)"
echo '{}' > "${TMP_DOCKER_CONFIG}/config.json"
trap 'rm -rf "${TMP_DOCKER_CONFIG}"' EXIT
export DOCKER_CONFIG="${TMP_DOCKER_CONFIG}"

docker run --rm \
  -u "${HOST_UID}:${HOST_GID}" \
  -v "${CERT_DIR}:/certs" \
  -w /certs \
  "${ES_IMAGE}" \
  bash -c '
    set -euo pipefail
    # 1) Build a CA (PEM, so we can extract ca.crt for Kibana/Fluentd)
    /usr/share/elasticsearch/bin/elasticsearch-certutil ca \
      --pem --silent --days 3650 \
      --out /tmp/ca.zip
    unzip -o /tmp/ca.zip -d /tmp/ >/dev/null
    cp /tmp/ca/ca.crt /certs/ca.crt
    cp /tmp/ca/ca.key /certs/ca.key

    # 2) Build a node keystore signed by that CA (PKCS12, no password).
    #    SAN covers the StatefulSet pod DNS + both services.
    /usr/share/elasticsearch/bin/elasticsearch-certutil cert \
      --silent --days 3650 \
      --ca-cert /tmp/ca/ca.crt \
      --ca-key  /tmp/ca/ca.key \
      --pass "" \
      --name elasticsearch \
      --dns elasticsearch \
      --dns elasticsearch.logging.svc.cluster.local \
      --dns elasticsearch-client.logging.svc.cluster.local \
      --dns localhost \
      --ip  127.0.0.1 \
      --out /certs/elastic-certificates.p12
  '

chmod 600 "${CERT_DIR}/ca.key" "${CERT_DIR}/elastic-certificates.p12"
chmod 644 "${CERT_DIR}/ca.crt"

echo "Wrote:"
ls -la "${CERT_DIR}"
