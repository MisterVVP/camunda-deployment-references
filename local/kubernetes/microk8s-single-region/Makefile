SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -euo pipefail -c
.NOTPARALLEL:

CAMUNDA_NAMESPACE ?= camunda
CAMUNDA_RELEASE_NAME ?= camunda
CERT_DIR ?= .certs
STATE_DIR := $(abspath .state)
TOOLS_BIN := $(abspath .tools/bin)
BUNDLED_BIN := $(abspath bin)
KUBECONFIG := $(STATE_DIR)/kubeconfig
KUBECACHEDIR := $(STATE_DIR)/kubectl-cache
HELM_CACHE_HOME := $(STATE_DIR)/helm/cache
HELM_CONFIG_HOME := $(STATE_DIR)/helm/config
HELM_DATA_HOME := $(STATE_DIR)/helm/data
DEPLOYMENT_READY_TIMEOUT_SECONDS ?= 900

export PATH := $(TOOLS_BIN):$(BUNDLED_BIN):$(PATH)
export CAMUNDA_NAMESPACE CAMUNDA_RELEASE_NAME CERT_DIR STATE_DIR KUBECONFIG KUBECACHEDIR
export HELM_CACHE_HOME HELM_CONFIG_HOME HELM_DATA_HOME
export DEPLOYMENT_READY_TIMEOUT_SECONDS SECONDARY_STORAGE INGRESS_PROVIDER INGRESS_ADDRESS
export PURGE_MKCERT_CA PURGE_PREREQUISITES FORCE_PURGE

PROCEDURE_DIR := ./procedure

.PHONY: help
help:
	@echo "Camunda 8 on MicroK8s - Local Development"
	@echo ""
	@echo "Golden path (installs/checks prerequisites, then deploys full TLS + Elasticsearch):"
	@echo "  ./install.sh"
	@echo "  ./install.sh --yes                    # non-interactive prerequisite acceptance"
	@echo "  ./install.sh --secondary-storage postgres"
	@echo "  ./install.sh --mode no-domain"
	@echo "  ./install.sh --ingress-provider traefik  # require/reuse existing Traefik"
	@echo ""
	@echo "Advanced/manual path:"
	@echo "  make prerequisites                    # install missing prerequisites only"
	@echo "  SECONDARY_STORAGE=elasticsearch make domain.init"
	@echo "  SECONDARY_STORAGE=postgres make domain.init"
	@echo "  SECONDARY_STORAGE=elasticsearch make no-domain.init"
	@echo "  SECONDARY_STORAGE=postgres make no-domain.init"
	@echo ""
	@echo "Cleanup:"
	@echo "  make purge                            # remove deployment + repo-local bootstrap tools"
	@echo "  PURGE_PREREQUISITES=1 make purge      # also undo host prerequisites installed by bootstrap"
	@echo "  PURGE_MKCERT_CA=1 make purge          # also uninstall a pre-existing mkcert CA"
	@echo "  make verify-clean                     # verify there are no Camunda leftovers"
	@echo ""
	@echo "Utilities:"
	@echo "  make status"
	@echo "  make port-forward"
	@echo "  make get-password"
	@echo "  make get-keycloak-password"

.PHONY: prerequisites
prerequisites:
	@$(PROCEDURE_DIR)/install-prerequisites.sh

.PHONY: prerequisites.check
prerequisites.check:
	@$(PROCEDURE_DIR)/install-prerequisites.sh --check

.PHONY: validate-storage
validate-storage:
	@if [[ -z "$${SECONDARY_STORAGE:-}" ]]; then \
		echo "ERROR: SECONDARY_STORAGE is required (elasticsearch or postgres)." >&2; exit 1; \
	fi
	@if [[ "$$SECONDARY_STORAGE" != "elasticsearch" && "$$SECONDARY_STORAGE" != "postgres" ]]; then \
		echo "ERROR: SECONDARY_STORAGE must be elasticsearch or postgres." >&2; exit 1; \
	fi

.PHONY: domain.init
domain.init: validate-storage prerequisites.check cluster.prepare ingress.configure coredns.config hosts.add certs.generate certs.create-secret certs.create-ca-configmap operators.deploy-domain identity-secrets.create camunda.deploy-domain camunda.wait
	@echo ""
	@echo "✓ Camunda on MicroK8s is ready"
	@echo "  https://camunda.example.com"
	@$(PROCEDURE_DIR)/kind-helper.sh get-password.sh | sed 's/^/  admin password: /'

.PHONY: no-domain.init
no-domain.init: validate-storage prerequisites.check cluster.prepare hosts.add-keycloak operators.deploy-no-domain identity-secrets.create camunda.deploy-no-domain camunda.wait
	@echo ""
	@echo "✓ Camunda on MicroK8s is ready"
	@echo "  Run: make port-forward"

# For MicroK8s, clean means restoring the existing cluster instead of deleting it.
.PHONY: domain.clean no-domain.clean
domain.clean no-domain.clean: purge

.PHONY: cluster.prepare
cluster.prepare:
	@$(PROCEDURE_DIR)/cluster-prepare.sh

.PHONY: ingress.configure ingress.deploy
ingress.configure:
	@$(PROCEDURE_DIR)/ingress-configure.sh

# Backwards-compatible alias for development scripts that used the old target.
ingress.deploy: ingress.configure

.PHONY: coredns.config
coredns.config:
	@$(PROCEDURE_DIR)/coredns-config.sh add

.PHONY: hosts.add
hosts.add:
	@$(PROCEDURE_DIR)/hosts.sh add-domain

.PHONY: hosts.add-keycloak
hosts.add-keycloak:
	@$(PROCEDURE_DIR)/hosts.sh add-keycloak

.PHONY: certs.generate
certs.generate:
	@$(PROCEDURE_DIR)/certs-generate.sh

.PHONY: certs.create-secret
certs.create-secret:
	@$(PROCEDURE_DIR)/certs-create-secret.sh

.PHONY: certs.create-ca-configmap
certs.create-ca-configmap:
	@$(PROCEDURE_DIR)/certs-create-ca-configmap.sh

.PHONY: operators.deploy-domain
operators.deploy-domain: validate-storage
	@CAMUNDA_MODE=domain $(PROCEDURE_DIR)/operators-deploy.sh

.PHONY: operators.deploy-no-domain
operators.deploy-no-domain: validate-storage
	@CAMUNDA_MODE=no-domain $(PROCEDURE_DIR)/operators-deploy.sh

.PHONY: identity-secrets.create
identity-secrets.create:
	@$(PROCEDURE_DIR)/kind-helper.sh create-identity-secrets.sh

.PHONY: camunda.deploy-domain
camunda.deploy-domain: validate-storage
	@$(PROCEDURE_DIR)/camunda-deploy.sh domain

.PHONY: camunda.deploy-no-domain
camunda.deploy-no-domain: validate-storage
	@$(PROCEDURE_DIR)/camunda-deploy.sh no-domain

.PHONY: camunda.wait
camunda.wait:
	@echo "Waiting for Camunda pods to be ready..."
	@../../../generic/kubernetes/single-region/procedure/check-deployment-ready.sh

.PHONY: camunda.uninstall
camunda.uninstall:
	@helm uninstall $(CAMUNDA_RELEASE_NAME) --namespace $(CAMUNDA_NAMESPACE) || true

.PHONY: purge
purge:
	@$(PROCEDURE_DIR)/purge.sh
	@$(PROCEDURE_DIR)/cleanup-prerequisites.sh

.PHONY: verify-clean
verify-clean:
	@$(PROCEDURE_DIR)/verify-clean.sh

.PHONY: status
status:
	@$(PROCEDURE_DIR)/status.sh

.PHONY: port-forward
port-forward:
	@$(PROCEDURE_DIR)/kind-helper.sh port-forward.sh

.PHONY: get-password
get-password:
	@$(PROCEDURE_DIR)/kind-helper.sh get-password.sh

.PHONY: get-keycloak-password
get-keycloak-password:
	@$(PROCEDURE_DIR)/kind-helper.sh get-keycloak-password.sh
