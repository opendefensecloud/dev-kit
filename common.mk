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

# Binaries provided by flake.nix
FLUX ?= flux
GO ?= go
HELM ?= helm
JQ ?= jq
KIND ?= kind
KUBECTL ?= kubectl
SHELLCHECK ?= shellcheck
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
CRD_REF_DOCS ?= $(LOCALGOBIN)/crd-ref-docs
GINKGO ?= $(LOCALGOBIN)/ginkgo
GOLANGCI_LINT ?= $(LOCALGOBIN)/golangci-lint
HELM_DOCS ?= $(LOCALGOBIN)/helm-docs
OCM ?= $(LOCALGOBIN)/ocm
OPENAPI_GEN ?= $(LOCALGOBIN)/openapi-gen
OPENAPI_GEN ?= $(LOCALGOBIN)/openapi-gen
OSV_SCANNER ?= $(LOCALGOBIN)/osv-scanner
SETUP_ENVTEST ?= $(LOCALGOBIN)/setup-envtest

##@ Repository

define REPO_LABELS
bug;d73a4a;Something isn't working
documentation;0075ca;Improvements or additions to documentation
duplicate;cfd3d7;This issue or pull request already exists
enhancement;a2eeef;New feature or request
good first issue;7057ff;Good for newcomers
help wanted;008672;Extra attention is needed
invalid;e4e669;This doesn't seem right
question;37326e;Further information is requested
wontfix;ffffff;This will not be worked on
chore;ededed;A routine task or common potentially re-occurring task
feature;a2eeef;New feature or request
go;16e2e2;Pull requests that update go code
ok-to-helm;0e8a16;PR is allowed to build an publish helm chart
dependencies;0366d6;Pull requests that update a dependency file
github-actions;80c4c6;PR created via GitHub action
help-wanted;811857;Extra attention is needed
good-first-issue;7057ff;Good for newcomers
needs-triage;eab668;Issue that has not been reviewed
ok-to-image;0e8a16;PR is allowed to run container build
ok-to-test;0e8a16;PR is allowed to be tested
spike;b23adb;A task to research a question and resolve problems
endef
export REPO_LABELS

REPO_RULESET := { \
	"name": "protect-main", \
	"target": "branch", \
	"enforcement": "active", \
	"conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } }, \
	"rules": [ \
		{ "type": "deletion" }, \
		{ "type": "non_fast_forward" }, \
		{ "type": "creation" }, \
		{ "type": "required_signatures" }, \
		{ "type": "pull_request", "parameters": { \
			"required_approving_review_count": 1, \
			"dismiss_stale_reviews_on_push": true, \
			"required_reviewers": [], \
			"require_code_owner_review": false, \
			"require_last_push_approval": false, \
			"required_review_thread_resolution": true, \
			"allowed_merge_methods": ["squash", "rebase", "merge"] \
		}} \
	], \
	"bypass_actors": [{ "actor_type": "OrganizationAdmin", "bypass_mode": "always" }] \
}

.PHONY: repo-settings
repo-settings: ## Reconcile GitHub repository settings (labels, merge strategy, branch protection, security)
	@$(GH) auth status >/dev/null 2>&1 || { echo "error: gh is not authenticated; run 'gh auth login'"; exit 1; }; \
	REPO=$$($(GH) repo view --json nameWithOwner -q .nameWithOwner) || { echo "error: not a GitHub repository"; exit 1; }; \
	echo "Reconciling settings for $$REPO..."; \
	\
	echo "  Syncing labels..."; \
	echo "$$REPO_LABELS" | while IFS=';' read -r name color desc; do \
		[ -z "$$name" ] && continue; \
		$(GH) label create "$$name" --repo "$$REPO" --color "$$color" --description "$$desc" --force 2>/dev/null; \
	done; \
	\
	echo "  Configuring merge strategy..."; \
	$(GH) api "repos/$$REPO" -X PATCH \
		-f allow_merge_commit=true \
		-f allow_squash_merge=false \
		-f allow_rebase_merge=false \
		-f delete_branch_on_merge=true \
		-f allow_auto_merge=true > /dev/null; \
	\
	echo "  Enabling secret scanning..."; \
	$(GH) api "repos/$$REPO" -X PATCH \
		--input <(echo '{"security_and_analysis":{"secret_scanning":{"status":"enabled"}}}') > /dev/null; \
	\
	echo "  Configuring branch protection ruleset..."; \
	existing=$$($(GH) api "repos/$$REPO/rulesets" -q '.[] | select(.name=="protect-main") | .id' 2>/dev/null); \
	if [ -n "$$existing" ]; then \
		$(GH) api "repos/$$REPO/rulesets/$$existing" -X PUT --input <(echo '$(REPO_RULESET)') > /dev/null; \
		echo "    Updated existing ruleset (id: $$existing)"; \
	else \
		$(GH) api "repos/$$REPO/rulesets" -X POST --input <(echo '$(REPO_RULESET)') > /dev/null; \
		echo "    Created new ruleset"; \
	fi; \
	\
	echo "  Installing update-action-pins workflow..."; \
	mkdir -p .github/workflows; \
	printf '%s\n' \
		'name: Update Action Pins' \
		'' \
		'on:' \
		'  pull_request:' \
		'    paths:' \
		'      - ".github/workflows/**"' \
		'' \
		'jobs:' \
		'  check-pins:' \
		'    name: Check action pins' \
		'    runs-on: ubuntu-latest' \
		'    steps:' \
		'      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4' \
		'      - name: Verify all actions are pinned to a SHA' \
		'        run: |' \
		'          unpinned=$$(grep -rE ''^\s+(- )?uses: '' .github/workflows/ \' \
		'            | grep -vE ''^\s+(- )?uses: \.\/'' \' \
		'            | grep -vE ''@[0-9a-f]{40}($$|\s)'' || true)' \
		'          if [[ -n "$$unpinned" ]]; then' \
		'            echo "::error::Found unpinned GitHub Actions (must use SHA digest, not tag):"' \
		'            echo "$$unpinned"' \
		'            echo ""' \
		'            echo "Run '"'"'GITHUB_TOKEN=$$(gh auth token) update-action-pins .github/workflows/'"'"' to fix."' \
		'            exit 1' \
		'          fi' \
		> .github/workflows/update-action-pins.yml; \
	echo "    Wrote .github/workflows/update-action-pins.yml"; \
	\
	echo "Done."

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
	rm -rf $(LOCALBIN)

.PHONY: shellcheck
shellcheck:  ## run shellcheck
	$(SHELLCHECK) $$(git ls-files '*\.sh')

OSV_SCANNER_CONFIG ?= ./.osv-scanner.toml
.PHONY: scan
scan: $(OSV_SCANNER)  ## scan for vulnerabilities
	$(OSV_SCANNER) scan --config $(OSV_SCANNER_CONFIG) -r .

.PHONY: addlicense
addlicense: $(ADDLICENSE)  ## Add License headers containing of `license` and `comment` to files matched by `pattern`.
	@test -n "$(license)" && test -n "$(comment)" && test -n "$(pattern)" && \
		git ls-files '$(pattern)' | xargs -r $(ADDLICENSE) -c '$(comment)' -l '$(license)' -s=only $(extraargs)

.PHONY: addlicense-check
addlicense-check:
	$(MAKE) addlicense extraargs='-check'

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

##@ Common golang targets
.PHONY: mod
mod: ## run go mod tidy, download, verify
	@$(GO) mod tidy
	@$(GO) mod download
	@$(GO) mod verify

.PHONY: golangci-lint
golangci-lint: $(GOLANGCI_LINT) ## run golangci-lint
	$(GOLANGCI_LINT) run -v

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
