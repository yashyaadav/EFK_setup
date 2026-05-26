
# EFK Setup on Minikube Cluster

Elasticsearch will be installed first as a StatefulSet which will store all data as indexed.
Fluentd will be installed as a DaemonSet so that logs can be captured from all nodes.
Kibana will be installed as a Deployment so that it can query the Elasticsearch server and run dashboards.

All resources deploy into the `logging` namespace. The stack is organized with Kustomize:

```
base/                # canonical manifests (namespace, labels, no env-specific tuning)
overlays/minikube/   # single-replica ES, NodePort Kibana on 30000
overlays/cloud/      # 3-replica ES, ClusterIP Kibana (front with Ingress)
```

## Install on Minikube

```
kubectl apply -k overlays/minikube
```

This applies the namespace, Elasticsearch StatefulSet (1 replica), headless service, Fluentd RBAC + DaemonSet, and Kibana Deployment + NodePort Service.

## Install on a cloud cluster (EKS / GKE / AKS)

```
kubectl apply -k overlays/cloud
```

3-replica ES with podAntiAffinity. Edit `overlays/cloud/patches/es-statefulset.yaml` to set the `storageClassName` for your provider, and front Kibana with your own Ingress.

## Validate the EFK Cluster

Run a pod in any namespace to generate log traffic:

```
kubectl run nginx --image=nginx --restart=Never
kubectl run mycurlpod --image=curlimages/curl -i --tty -- sh
```

Then open Kibana:

```
# Minikube
minikube service kibana -n logging --url

# Or via port-forward (any cluster)
kubectl -n logging port-forward svc/kibana 5601:5601
```
