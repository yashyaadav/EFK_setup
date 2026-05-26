.DEFAULT_GOAL := help
SHELL := /bin/bash

OVERLAY ?= minikube
NS      := logging
CERT_DIR := certs

.PHONY: help
help: ## Show this help
	@awk 'BEGIN{FS=":.*##"; printf "Usage: make <target> [OVERLAY=minikube|cloud]\n\nTargets:\n"} \
		/^[a-zA-Z_-]+:.*##/ {printf "  %-18s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

##@ Bootstrap

.PHONY: tls-certs
tls-certs: ## Generate CA + node PKCS12 keystore into ./certs (idempotent)
	@hack/gen-certs.sh

.PHONY: secrets
secrets: tls-certs ## Materialize the three in-cluster Secrets (passwords + certs)
	@command -v kubectl >/dev/null || { echo "kubectl not on PATH"; exit 1; }
	@kubectl get ns $(NS) >/dev/null 2>&1 || kubectl apply -f base/namespace.yaml
	@if [[ ! -f .env ]]; then \
		echo "Generating .env with random elastic + encryption key…"; \
		printf 'ELASTIC_PASSWORD=%s\nXPACK_ENCRYPTIONKEY=%s\n' \
			"$$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-24)" \
			"$$(openssl rand -base64 48 | tr -d '=+/' | cut -c1-32)" > .env; \
		chmod 600 .env; \
	fi
	@set -a; source .env; set +a; \
	kubectl create secret generic elastic-credentials -n $(NS) \
		--from-literal=password="$$ELASTIC_PASSWORD" \
		--from-literal=xpack_encryptionkey="$$XPACK_ENCRYPTIONKEY" \
		--dry-run=client -o yaml | kubectl apply -f - ; \
	kubectl create secret generic es-tls -n $(NS) \
		--from-file=elastic-certificates.p12=$(CERT_DIR)/elastic-certificates.p12 \
		--from-file=ca.crt=$(CERT_DIR)/ca.crt \
		--dry-run=client -o yaml | kubectl apply -f - ; \
	kubectl create secret generic es-ca -n $(NS) \
		--from-file=ca.crt=$(CERT_DIR)/ca.crt \
		--dry-run=client -o yaml | kubectl apply -f -

##@ Deploy

.PHONY: namespace
namespace: ## Apply just the namespace + PSA labels
	@kubectl apply -f base/namespace.yaml

.PHONY: up
up: namespace secrets ## Deploy the stack (OVERLAY=minikube by default)
	@kubectl apply -k overlays/$(OVERLAY)
	@echo "Applied overlays/$(OVERLAY). Run \`make wait\` to block until Ready."

.PHONY: wait
wait: ## Wait until all EFK pods are Ready (5 min timeout)
	@kubectl -n $(NS) wait --for=condition=ready pod \
		-l app.kubernetes.io/part-of=efk --timeout=300s

.PHONY: down
down: ## Tear the stack down (prompts before deleting PVCs)
	@kubectl delete -k overlays/$(OVERLAY) --ignore-not-found=true
	@read -p "Also delete Elasticsearch PVCs (logs will be lost)? [y/N] " ans; \
		if [[ "$$ans" == "y" || "$$ans" == "Y" ]]; then \
			kubectl -n $(NS) delete pvc -l app.kubernetes.io/name=elasticsearch --ignore-not-found=true; \
		fi

##@ Verify & access

.PHONY: smoke
smoke: ## Run hack/smoke.sh end-to-end checks
	@hack/smoke.sh

.PHONY: validate
validate: ## Render manifests with kustomize, sanity-check structure (no cluster)
	@kubectl kustomize overlays/minikube >/dev/null && echo "minikube overlay OK"
	@kubectl kustomize overlays/cloud    >/dev/null && echo "cloud overlay OK"

.PHONY: kibana
kibana: ## Open Kibana in a browser (minikube NodePort)
	@if [[ "$(OVERLAY)" == "minikube" ]]; then \
		minikube service kibana -n $(NS); \
	else \
		echo "Cloud overlay uses ClusterIP. Use 'make port-forward' instead."; \
	fi

.PHONY: port-forward
port-forward: ## Port-forward Kibana to localhost:5601
	@kubectl -n $(NS) port-forward svc/kibana 5601:5601

.PHONY: elastic-password
elastic-password: ## Print the elastic user password
	@kubectl -n $(NS) get secret elastic-credentials -o jsonpath='{.data.password}' | base64 -d; echo

##@ Maintenance

.PHONY: clean
clean: ## Remove locally-generated certs and .env (does NOT touch the cluster)
	@rm -rf $(CERT_DIR) .env
	@echo "Removed ./certs and .env"
