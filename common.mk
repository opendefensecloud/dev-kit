
# Setting SHELL to bash allows bash commands to be executed by recipes.
# Options are set to exit when a recipe line exits non-zero or a piped command fails.
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

# Set MAKEFLAGS to suppress entering/leaving directory messages
MAKEFLAGS += --no-print-directory

BUILD_PATH ?= $(shell pwd)

LOCALBIN ?= $(BUILD_PATH)/bin
$(LOCALBIN):
	mkdir -p $(LOCALBIN)

LOCALGOBIN := $(LOCALBIN)/go
$(LOCALGOBIN): $(LOCALBIN)
	mkdir -p $(LOCALGOBIN)

OS := $(shell $(GO) env GOOS)
ARCH := $(shell $(GO) env GOARCH)

# Binaries from flake.nix
FLUX ?= flux
GO ?= go
HELM ?= helm
JQ ?= jq
KIND ?= kind
KUBECTL ?= kubectl
SHELLCHECK ?= shellcheck
YQ ?= yq

# Binaries from go install
ADDLICENSE ?= $(LOCALGOBIN)/addlicense
CONTROLLER_GEN ?= $(LOCALGOBIN)/controller-gen
CRD_REF_DOCS ?= $(LOCALGOBIN)/crd-ref-docs
GINKGO ?= $(LOCALGOBIN)/ginkgo
GOLANGCI_LINT ?= $(LOCALGOBIN)/golangci-lint
HELM_DOCS ?= $(LOCALGOBIN)/helm-docs
OPENAPI_GEN ?= $(LOCALGOBIN)/openapi-gen
OPENAPI_GEN ?= $(LOCALGOBIN)/openapi-gen
OSV_SCANNER ?= $(LOCALGOBIN)/osv-scanner
SETUP_ENVTEST ?= $(LOCALGOBIN)/setup-envtest

##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk commands is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

.PHONY: clean
clean:
	rm -rf $(LOCALBIN)

.PHONY: mod
mod: ## Do go mod tidy, download, verify
	@$(GO) mod tidy
	@$(GO) mod download
	@$(GO) mod verify

## Common linting tasks
.PHONY: golangci-lint
golangci-lint: $(GOLANGCI_LINT)
	$(GOLANGCI_LINT) run -v

.PHONY: shellcheck
shellcheck:
	$(SHELLCHECK) $$(git ls-files | grep '.*.sh$$')

OSV_SCANNER_CONFIG ?= ./.osv-scanner.toml
.PHONY: scan
scan: $(OSV_SCANNER)
	$(OSV_SCANNER) scan --config $(OSV_SCANNER_CONFIG) -r .

# Local dev environment
.PHONY: setup-local-cluster
setup-local-cluster: ## Set up a Kind cluster for local development if it does not exist
	@command -v $(KIND) >/dev/null 2>&1 || { \
		echo "Kind is not installed. Please install Kind manually."; \
		exit 1; \
	}
	@case "$$($(KIND) get clusters)" in \
		*"$(KIND_CLUSTER)"*) \
			echo "Kind cluster '$(KIND_CLUSTER)' already exists. Skipping creation." ;; \
		*) \
			echo "Creating Kind cluster '$(KIND_CLUSTER)'..."; \
			$(KIND) create cluster --name $(KIND_CLUSTER) ;; \
	esac

# Install local tools
TOOL_LOCK := $(BUILD_PATH)/tools.lock

.PHONY: $(filter $(LOCALGOBIN)/%,$(MAKECMDGOALS))
$(LOCALGOBIN)/%: $(LOCALGOBIN) $(TOOL_LOCK)
	@toolname=$(notdir $@); \
	module=$$(awk "/^$$toolname / {print \$$2}" $(TOOL_LOCK)); \
	version=$$(cut -d@ -f2 <<< $$module); \
	test -s $(LOCALGOBIN)/$$toolname && grep -q "$$version" $(LOCALGOBIN)/.$$toolname-version 2>/dev/null || \
		(GOBIN=$(LOCALGOBIN) $(GO) install $$module && echo $$version > $(LOCALGOBIN)/.$$toolname-version)
