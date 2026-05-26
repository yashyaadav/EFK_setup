# Troubleshooting

A cookbook of failures seen in this stack and how to diagnose each. All commands assume the `logging` namespace; substitute if you ran with a different one.

## Elasticsearch

### ES pod is CrashLoopBackOff; logs show `max virtual memory areas vm.max_map_count [65530] is too low`

The `increase-vm-max-map` init container didn't run or didn't take effect. On Docker Desktop / minikube, this is sometimes blocked by host kernel settings. Check:

```bash
kubectl -n logging describe pod es-cluster-0 | sed -n '/Init Containers/,/Containers:/p'
```

If the init container is in `CreateContainerConfigError` with a PodSecurity violation message, the namespace is set to `restricted` somewhere. Verify:

```bash
kubectl get ns logging -o jsonpath='{.metadata.labels}' | tr , '\n'
```

It should show `pod-security.kubernetes.io/enforce: baseline`. If a controller is overriding, that's the bug.

### ES PVC stuck in Pending

```bash
kubectl -n logging describe pvc data-es-cluster-0 | tail -10
```

If it says `no persistent volumes available for this claim and no storage class is set`, you have no default StorageClass. On minikube:

```bash
minikube addons enable default-storageclass
minikube addons enable storage-provisioner
```

### ES cluster status stays `yellow` forever (multi-replica)

Usually a `cluster.initial_master_nodes` / `discovery.seed_hosts` mismatch. Check that all three node names match your replica count:

```bash
kubectl -n logging exec es-cluster-0 -- env | grep -E 'discovery|initial_master'
```

For the single-replica minikube overlay, `yellow` is expected (no replicas to host shards). That's fine.

### `make smoke` step 2 reports `cluster status: unreachable`

The exec into `es-cluster-0` failed. Either the pod isn't Ready or the `elastic` password in the Secret doesn't match what ES bootstrapped with. If you regenerated `make secrets` without restarting ES, the env was updated but the running container still has the old password. Restart:

```bash
kubectl -n logging rollout restart statefulset/es-cluster
```

## Kibana

### Kibana stuck on "Kibana server is not ready yet"

```bash
kubectl -n logging logs deploy/kibana | tail -50
```

Common causes:

- `Authentication required` / `401` → password mismatch with what ES has. See the ES section above.
- `unable to verify the first certificate` / `self signed certificate in certificate chain` → CA mount wrong. Verify:
  ```bash
  kubectl -n logging exec deploy/kibana -- ls /usr/share/kibana/config/certs
  ```
  should list `ca.crt`. If empty, the `es-ca` Secret wasn't created — re-run `make secrets`.
- `Unable to retrieve version information from Elasticsearch nodes` → DNS or NetworkPolicy. Try `kubectl -n logging exec deploy/kibana -- curl -k https://elasticsearch-client:9200`. If it times out, the NetworkPolicy isn't admitting Kibana — check label selectors on both ends.

### Kibana shows no logs / "No results found"

You probably haven't created an index pattern. In **Stack Management → Index Patterns → Create index pattern**, type `logstash-*` and pick `@timestamp` as the time field.

If the index pattern exists but searches still return nothing, check that Fluentd actually wrote anything:

```bash
make elastic-password   # grab the password
kubectl -n logging exec es-cluster-0 -- curl -fsS \
  -u "elastic:$(make elastic-password)" \
  --cacert /usr/share/elasticsearch/config/certs/ca.crt \
  https://localhost:9200/_cat/indices/logstash-\*?v
```

If the table is empty, the problem is in Fluentd — next section.

## Fluentd

### Fluentd not shipping any logs

Walk the chain from Fluentd outward:

1. **Pod up?** `kubectl -n logging get ds/fluentd` — `DESIRED == READY`?
2. **Reading host logs?** `kubectl -n logging logs -l app.kubernetes.io/name=fluentd --tail=20`. You should see `fluent.info` lines about following `/var/log/containers/*.log`.
3. **Can it resolve ES?** `kubectl -n logging exec ds/fluentd -- getent hosts elasticsearch-client`. Returns an IP?
4. **Can it reach ES on 9200?** The NetworkPolicy should allow it. Check Fluentd logs for `connect timeout` or `no Elasticsearch node available`.
5. **TLS verify?** If you see `certificate verify failed`, the CA mount is wrong. `kubectl -n logging exec ds/fluentd -- ls /fluentd/etc/certs` should show `ca.crt`. To temporarily bypass and confirm it's a TLS issue, edit the DaemonSet:
   ```yaml
   - name: FLUENT_ELASTICSEARCH_SSL_VERIFY
     value: "false"
   ```
   Re-apply. If logs start flowing, the bug is in the CA path or content.
6. **Auth?** `401`/`403` from ES → password mismatch (see ES section).

### Fluentd OOMKilled

The memory limit is 768 Mi. With a busy cluster you may need more, or you can tune the buffer in `base/fluentd/configmap-fluent-conf.yaml`:

```
<buffer>
  flush_interval 5s
  chunk_limit_size 8M
  total_limit_size 256M
</buffer>
```

Lower `total_limit_size` reduces memory at the cost of dropping logs under back-pressure.

### Fluentd shipping the `logging` namespace's own logs (feedback loop)

Shouldn't happen — the `fluent.conf` has a `<match kubernetes.var.log.containers.**_logging_**.log>` rule that drops them. If you're seeing it, your fluent.conf ConfigMap didn't get mounted. Confirm:

```bash
kubectl -n logging exec ds/fluentd -- cat /fluentd/etc/fluent.conf | head -20
```

You should see the `monitor_agent` source first. If you see the image's default config instead, the volumeMount didn't take — check `subPath: fluent.conf`.

## NetworkPolicy

### App pod can suddenly no longer reach ES after applying this stack

That's the point of the NetworkPolicy. Only pods labeled `app.kubernetes.io/name in (kibana, fluentd)` and inside the `logging` namespace can hit ES 9200. If you have a legitimate consumer (say, a separate log-query service), add an ingress rule to `base/elasticsearch/networkpolicy.yaml`:

```yaml
- from:
    - podSelector:
        matchLabels:
          app: my-query-service
  ports:
    - protocol: TCP
      port: 9200
```

If your minikube CNI doesn't enforce NetworkPolicies at all (the default `kindnet` or older minikube networking), the policies are no-ops. Switch CNI:

```bash
minikube start --cni=calico
```

## PSA warnings on apply

When `kubectl apply -k` runs, you'll see:

```
Warning: would violate PodSecurity "restricted:latest": privileged ...
```

This is expected and intentional — the namespace is `enforce: baseline` (so the pod is admitted) with `audit: restricted` and `warn: restricted` (so the gap is surfaced). See [security.md](security.md#why-not-just-use-restricted) for the rationale and the workaround path.

## Certs

### `make tls-certs` fails with "no such image" / "cannot connect to Docker daemon"

Docker isn't running, or the ES 7.14.0 image isn't pullable. Start Docker; if you're behind a proxy or air-gapped, pre-pull `docker.elastic.co/elasticsearch/elasticsearch:7.14.0` once.

### Cert expired

The CA is good for 10 years and the node cert for 10 years, so this shouldn't happen during normal use. If it does:

```bash
rm -rf certs/
make tls-certs
make secrets
kubectl -n logging rollout restart statefulset/es-cluster deployment/kibana daemonset/fluentd
```
