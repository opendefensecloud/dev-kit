# Setting SHELL to bash allows bash commands to be executed by recipes.
# Options are set to exit when a recipe line exits non-zero or a piped command fails.
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

# Capture the path to this file before any other includes can shift MAKEFILE_LIST.
_COMMON_MK_PATH := $(lastword $(MAKEFILE_LIST))

# Set MAKEFLAGS to suppress entering/leaving directory messages
MAKEFLAGS += --no-print-directory

BUILD_PATH ?= $(shell pwd)

# DEV_KIT_VERSION must be set by the including Makefile before -include common.mk.
# This fallback is for environments where common.mk is used standalone.
# Must precede ENVTEST_SIDELOAD, which expands it in a target name at parse time.
ifndef DEV_KIT_VERSION
  $(warning DEV_KIT_VERSION was not set, using default value "main". Please consider pinning the version to avoid unexpected upgrades.)
  DEV_KIT_VERSION := main
endif

LOCALBIN ?= $(BUILD_PATH)/bin
$(LOCALBIN):
	mkdir -p $(LOCALBIN)

LOCALGOBIN := $(LOCALBIN)/go
$(LOCALGOBIN): $(LOCALBIN)
	mkdir -p $(LOCALGOBIN)

# Binaries provided by flake.nix
FLUX ?= flux
GO ?= go
HELM ?= helm
JQ ?= jq
KIND ?= kind
KUBECTL ?= kubectl
MDFORMAT ?= mdformat
SHELLCHECK ?= shellcheck
SHFMT ?= shfmt
TREEFMT ?= treefmt
YAMLFMT ?= yamlfmt
YQ ?= yq

# External prerequisites (not managed by flake.nix or tools.lock)
GH ?= gh

OS := $(or $(shell $(GO) env GOOS 2>/dev/null), \
	$(shell uname -s | tr '[:upper:]' '[:lower:]'))
ARCH := $(or $(shell $(GO) env GOARCH 2>/dev/null), \
	$(shell uname -m | sed -E 's/x86_64/amd64/;s/i386|i686/386/;s/aarch64|arm64/arm64/;s/armv7l/arm/'))

# Binaries provided by go install / tools.lock
ADDLICENSE ?= $(LOCALGOBIN)/addlicense
CONTROLLER_GEN ?= $(LOCALGOBIN)/controller-gen
COSIGN ?= $(LOCALGOBIN)/cosign
CRD_REF_DOCS ?= $(LOCALGOBIN)/crd-ref-docs
GINKGO ?= $(LOCALGOBIN)/ginkgo
GOLANGCI_LINT ?= $(LOCALGOBIN)/golangci-lint
HELM_DOCS ?= $(LOCALGOBIN)/helm-docs
OCM ?= $(LOCALGOBIN)/ocm
OPENAPI_GEN ?= $(LOCALGOBIN)/openapi-gen
OSV_SCANNER ?= $(LOCALGOBIN)/osv-scanner
SETUP_ENVTEST ?= $(LOCALGOBIN)/setup-envtest

##@ Repository

# repo-settings — repository configuration, configurable per repository.
# Branch protection: the default branch is always protected; REPO_RULESET_BRANCHES
# adds further branch patterns (a JSON array, e.g. '["release/*"]'; short names are
# normalized to refs/heads/...). REPO_STATUS_CHECKS is a JSON array of status-check
# contexts that must pass (each job name is used as-is, so contexts with spaces work).
# REPO_ALLOW_MERGE_COMMIT/SQUASH_MERGE/REBASE_MERGE configure the merge strategy and
# the ruleset's allowed merge methods; at least one must be `true` (repo-settings fails otherwise).
# REPO_REQUIRE_LAST_PUSH_APPROVAL requires the most recent push to be approved before merging.
# Booleans must be `true` or `false`. Example:
#   make repo-settings REPO_ADMIN_BYPASS=false REPO_STATUS_CHECKS='["CI","Check action pins"]' REPO_RULESET_BRANCHES='["release/*"]'
REPO_ADMIN_BYPASS ?= true
REPO_REQUIRED_APPROVING_REVIEW_COUNT ?= 1
REPO_REQUIRE_CODE_OWNER_REVIEW ?= false
REPO_REQUIRE_BRANCH_UP_TO_DATE ?= false
REPO_STATUS_CHECKS ?= []
REPO_RULESET_BRANCHES ?= []
REPO_ALLOW_MERGE_COMMIT ?= true
REPO_ALLOW_SQUASH_MERGE ?= false
REPO_ALLOW_REBASE_MERGE ?= false
REPO_REQUIRE_LAST_PUSH_APPROVAL ?= false

.PHONY: repo-settings
repo-settings: ## Reconcile GitHub repository settings (labels, merge strategy, branch protection, security)
	@curl --fail -sSL \
		"https://raw.githubusercontent.com/opendefensecloud/dev-kit/$(DEV_KIT_VERSION)/scripts/repo-settings.sh" | \
		REPO_ADMIN_BYPASS='$(REPO_ADMIN_BYPASS)' \
		REPO_ALLOW_MERGE_COMMIT='$(REPO_ALLOW_MERGE_COMMIT)' \
		REPO_ALLOW_REBASE_MERGE='$(REPO_ALLOW_REBASE_MERGE)' \
		REPO_ALLOW_SQUASH_MERGE='$(REPO_ALLOW_SQUASH_MERGE)' \
		REPO_REQUIRE_BRANCH_UP_TO_DATE='$(REPO_REQUIRE_BRANCH_UP_TO_DATE)' \
		REPO_REQUIRE_CODE_OWNER_REVIEW='$(REPO_REQUIRE_CODE_OWNER_REVIEW)' \
		REPO_REQUIRED_APPROVING_REVIEW_COUNT='$(REPO_REQUIRED_APPROVING_REVIEW_COUNT)' \
		REPO_REQUIRE_LAST_PUSH_APPROVAL='$(REPO_REQUIRE_LAST_PUSH_APPROVAL)' \
		REPO_RULESET_BRANCHES='$(REPO_RULESET_BRANCHES)' \
		REPO_STATUS_CHECKS='$(REPO_STATUS_CHECKS)' \
		DEV_KIT_VERSION='$(DEV_KIT_VERSION)' \
		GH='$(GH)' JQ='$(JQ)' \
		bash

.PHONY: update-action-pins
update-action-pins: ## Update GitHub Action pins to their latest commit SHA
	@$(GH) auth status >/dev/null 2>&1 || { echo "error: gh is not authenticated; run 'gh auth login'"; exit 1; }; \
	GITHUB_TOKEN=$$(gh auth token) update-action-pins .github/workflows/

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
	-chmod -R u+w $(LOCALBIN)
	rm -rf $(LOCALBIN)

.PHONY: shellcheck
shellcheck:  ## run shellcheck
	$(SHELLCHECK) $$(git ls-files '*\.sh')

OSV_SCANNER_CONFIG ?= ./.osv-scanner.toml
.PHONY: scan
scan: $(OSV_SCANNER)  ## scan for vulnerabilities
	$(OSV_SCANNER) scan --config $(OSV_SCANNER_CONFIG) -r .

# Files subject to a license header: everything matching `pattern`, minus
# generated files.
addlicense_files = git ls-files '$(pattern)' | (xargs -r grep -L -E '^(//|\#) Code generated .* DO NOT EDIT\.$$' || true)

# The SPDX identifier expected in the header, and what addlicense writes for
# `license=apache`. Override `spdx` should a repository ever use another one.
spdx ?= Apache-2.0

# addlicense with -check, only ever sees a *missing* header, never an outdated
# one, and it never inspects the SPDX line at all; 
# `|| true` because grep -L exits 1 when it selects nothing, which
# .SHELLFLAGS = -ec would make fatal.
addlicense_mismatch = $$({ $(addlicense_files) | xargs -r grep -L -F 'Copyright $(comment)' || true; \
	$(addlicense_files) | xargs -r grep -L -F 'SPDX-License-Identifier: $(spdx)' || true; } | sort -u)

.PHONY: addlicense
addlicense: $(ADDLICENSE)  ## Add License headers containing of `license` and `comment` to files matched by `pattern`.
	@test -n "$(license)" && test -n "$(comment)" && test -n "$(pattern)" && \
		$(addlicense_files) | xargs -r $(ADDLICENSE) -c '$(comment)' -l '$(license)' -s=only -y '' $(extraargs)

.PHONY: addlicense-list
addlicense-list:  ## List files matched by `pattern` whose header does not carry `Copyright $(comment)` and `SPDX-License-Identifier: $(spdx)`.
	@test -n "$(comment)" && test -n "$(pattern)"
	@files=$(addlicense_mismatch); \
	if [ -n "$$files" ]; then \
		echo "Unexpected license header, expected 'Copyright $(comment)' and 'SPDX-License-Identifier: $(spdx)':"; \
		echo "$$files" | sed 's/^/  /'; \
	fi

.PHONY: addlicense-check
addlicense-check:
	$(MAKE) addlicense extraargs='-check'
	@$(MAKE) addlicense-list
	@test -z "$(addlicense_mismatch)"

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
			$(KIND) create cluster --name $(KIND_CLUSTER) $(if $(KIND_CONFIG),--config $(KIND_CONFIG)) ;; \
	esac

##@ Formatting and linting

# Shared configuration shipped from dev-kit. The rule only fires for a file that
# is absent, so a repository that commits its own copy silently overrides it.
DEV_KIT_CONFIGS ?= .editorconfig .golangci.yml treefmt.toml

$(DEV_KIT_CONFIGS):
	@curl --fail -sSL \
		'https://raw.githubusercontent.com/opendefensecloud/dev-kit/$(DEV_KIT_VERSION)/$@' \
		-o '$@.dev-kit-download'
	@mv '$@.dev-kit-download' '$@'
	@echo "fetched $@ from dev-kit $(DEV_KIT_VERSION)" >&2

# treefmt drives gofmt (via golangci-lint), yamlfmt, shfmt and mdformat from one
# config. LOCALGOBIN goes on PATH so it picks up the pinned golangci-lint from
# tools.lock rather than whatever happens to be installed. Repos without Go code
# skip that install and set TREEFMT_ARGS := --allow-missing-formatter.
TREEFMT_ARGS ?=
_TREEFMT_GO_TOOL := $(if $(wildcard go.mod),$(GOLANGCI_LINT))

.PHONY: fmt-all
fmt-all: $(_TREEFMT_GO_TOOL) ## Format every file in the repository
	@$(if $(DEV_KIT_CONFIGS),$(MAKE) $(DEV_KIT_CONFIGS) >/dev/null)
	@PATH="$(LOCALGOBIN):$$PATH" $(TREEFMT) $(TREEFMT_ARGS)

.PHONY: lint-all
lint-all: $(_TREEFMT_GO_TOOL) ## Fail if any file is not formatted
	@$(if $(DEV_KIT_CONFIGS),$(MAKE) $(DEV_KIT_CONFIGS) >/dev/null)
	@PATH="$(LOCALGOBIN):$$PATH" $(TREEFMT) --ci $(TREEFMT_ARGS)

# Public entry points. These names are what the flake git-hooks and every
# workflow call, so they stay stable. A repository extends them by adding
.PHONY: fmt
fmt: fmt-all ## Format code

.PHONY: lint
lint: lint-all shellcheck $(if $(wildcard go.mod),golangci-lint) ## Check formatting and run all linters

##@ Common golang targets
.PHONY: mod
mod: ## run go mod tidy, download, verify
	@$(GO) mod tidy
	@$(GO) mod download
	@$(GO) mod verify

.PHONY: golangci-lint
golangci-lint: $(GOLANGCI_LINT) ## run golangci-lint
	$(GOLANGCI_LINT) run -v

# Cached rather than piped to bash like repo-settings: this is a `make test`
# prerequisite and must not need the network once the envtest cache is warm.
# subst: DEV_KIT_VERSION may be a ref (refs/heads/main); slashes would become
# directory separators. `~` is illegal in a git ref, so the mapping cannot
# collide. tmp+mv: curl --fail leaves partial files on a dropped
# transfer and there is no .DELETE_ON_ERROR. Order-only: $(LOCALBIN)'s mtime is
# bumped by this very rename, so a normal prerequisite re-downloads every run.
# ponytail: floating DEV_KIT_VERSION pins the script until `make clean`; pin a tag.
ENVTEST_SIDELOAD := $(LOCALBIN)/envtest-sideload-$(subst /,~,$(DEV_KIT_VERSION)).sh
$(ENVTEST_SIDELOAD): | $(LOCALBIN)
	@curl --fail -sSL \
		"https://raw.githubusercontent.com/opendefensecloud/dev-kit/$(DEV_KIT_VERSION)/scripts/envtest-sideload.sh" \
		-o $@.download
	@mv $@.download $@

# ENVTEST_K8S_VERSION is deliberately not defaulted here: consumers set it with
# ?= *after* `-include common.mk`, so a default here would silently win.
.PHONY: envtest-binaries-sideload
envtest-binaries-sideload: $(SETUP_ENVTEST) $(ENVTEST_SIDELOAD) ## Populate the envtest cache for ENVTEST_K8S_VERSION from upstream K8s/etcd releases when controller-tools hasn't packaged it. No-op if already cached.
	@test -n "$(ENVTEST_K8S_VERSION)" || { echo "error: ENVTEST_K8S_VERSION is not set" >&2; exit 1; }
	@SETUP_ENVTEST=$(SETUP_ENVTEST) BIN_DIR=$(LOCALBIN) YQ=$(YQ) \
		bash $(ENVTEST_SIDELOAD) $(ENVTEST_K8S_VERSION)

# Install local tools
TOOL_LOCK := $(BUILD_PATH)/tools.lock

.PHONY: $(filter $(LOCALGOBIN)/%,$(MAKECMDGOALS))
$(LOCALGOBIN)/%: $(LOCALGOBIN) $(TOOL_LOCK)
	@toolname=$(notdir $@); \
	module=$$(awk "/^$$toolname / {print \$$2}" $(TOOL_LOCK)); \
	version=$$(cut -d@ -f2 <<< $$module); \
	test -s $(LOCALGOBIN)/$$toolname && grep -q "$$version" $(LOCALGOBIN)/.$$toolname-version 2>/dev/null || \
		(GOBIN=$(LOCALGOBIN) $(GO) install $$module && echo $$version > $(LOCALGOBIN)/.$$toolname-version)

# ocm cli (sdk v1) cannot be installed with go install because of replace directives in go.mod
$(LOCALGOBIN)/ocm: $(LOCALGOBIN) $(TOOL_LOCK)
	@module=$$(awk "/^ocm / {print \$$2}" $(TOOL_LOCK)); \
	version=$$(cut -d@ -f2 <<< $$module); \
	test -s $@ && grep -q "$$version" $(LOCALGOBIN)/.ocm-version 2>/dev/null || \
	curl -s https://ocm.software/install.sh | VERSION_OCM=$$version bash -s -- $(LOCALGOBIN) && echo $$version > $(LOCALGOBIN)/.ocm-version

# Rewrites the common.mk: rule in the calling project's Makefile to the current bootstrap format.
# Run once per repository to migrate from any older recipe shape.
.PHONY: update-common-mk-bootstrap
update-common-mk-bootstrap: ## Rewrite the common.mk: rule in Makefile to the current bootstrap format
	@tmp=Makefile.tmp; \
	awk ' \
	BEGIN { found = 0 } \
	/^common\.mk:$$/ { \
		found = 1; \
		print; \
		print "\t@[ -f .common.mk-download ] || \\"; \
		print "\t\tcurl --fail -sSL https://raw.githubusercontent.com/opendefensecloud/dev-kit/$$(DEV_KIT_VERSION)/common.mk \\"; \
		print "\t\t  -o .common.mk-download"; \
		print "\tmv .common.mk-download $$@"; \
		print "\tprintf \047%s\047 \047$$(DEV_KIT_VERSION)\047 > .common.mk-version"; \
		print "\ttouch .common.mk-checked"; \
		skip = 1; next \
	} \
	skip && /^\t/ { next } \
	{ skip = 0; print } \
	END { exit(found ? 0 : 1) } \
	' Makefile > "$$tmp" && mv "$$tmp" Makefile || { rm -f "$$tmp"; echo "error: common.mk: rule not found in Makefile" >&2; exit 1; }
	@echo "Updated common.mk: bootstrap in Makefile"

# ── Self-update ────────────────────────────────────────────────────────────────
# The DEV_KIT_VERSION fallback lives near the top of this file, because targets
# that embed it in a *target name* (see ENVTEST_SIDELOAD) need it at parse time.

# Performs a content-based staleness check at most once per hour.
# If the remote content differs from the local file, deletes this file so that
# Make's include-file-remake mechanism triggers the project's common.mk: rule on
# its next restart — picking up the pre-downloaded .common.mk-download file.
# DEV_KIT_NO_SELF_UPDATE=1 disables this. dev-kit's own Makefile sets it: there
# common.mk is the source file, and the staleness check would delete it.
_COMMON_MK_SELF_UPDATE := $(shell \
  [ -z '$(DEV_KIT_NO_SELF_UPDATE)' ] || exit 0; \
  hash_cmd=$$(command -v sha256sum >/dev/null 2>&1 && echo "sha256sum" || echo "shasum -a 256"); \
  stored=$$(cat .common.mk-version 2>/dev/null); \
  if [ "$$stored" != "$(DEV_KIT_VERSION)" ]; then \
    rm -f .common.mk-checked .common.mk-download; \
    for f in $(DEV_KIT_CONFIGS); do \
      git ls-files --error-unmatch "$$f" >/dev/null 2>&1 || rm -f "$$f"; \
    done; \
  elif find .common.mk-checked -mmin -60 2>/dev/null | grep -q .; then \
    exit 0; \
  fi; \
  if curl --fail -sSL \
      'https://raw.githubusercontent.com/opendefensecloud/dev-kit/$(DEV_KIT_VERSION)/common.mk' \
      -o .common.mk-download 2>/dev/null; then \
    remote=$$($$hash_cmd .common.mk-download | cut -d' ' -f1); \
    local_hash=$$($$hash_cmd '$(_COMMON_MK_PATH)' 2>/dev/null | cut -d' ' -f1); \
	printf '%s' '$(DEV_KIT_VERSION)' > .common.mk-version; \
    if [ "$$remote" = "$$local_hash" ]; then \
      rm -f .common.mk-download; \
      touch .common.mk-checked; \
    else \
      rm -f '$(_COMMON_MK_PATH)'; \
    fi; \
  else \
    echo >&2 'warning: could not fetch common.mk update, using cached version'; \
    touch .common.mk-checked; \
  fi)
