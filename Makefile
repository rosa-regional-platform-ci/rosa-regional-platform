.PHONY: help terraform-fmt terraform-init terraform-validate terraform-upgrade terraform-output-management terraform-output-regional provision-management provision-regional apply-infra-management apply-infra-regional provision-maestro-agent-iot-regional cleanup-maestro-agent-iot destroy-management destroy-regional build-platform-image test-e2e helm-lint check-rendered-files ephemeral-preflight ephemeral-provision ephemeral-teardown ephemeral-resync ephemeral-list

# Default target
help:
	@echo "🚀 Cluster Provisioning / Deprovisioning:"
	@echo "  provision-management                  - Provision management cluster (infra & argocd bootstrap)"
	@echo "  provision-regional                    - Provision regional cluster (infra & argocd bootstrap)"
	@echo "  destroy-management                    - Destroy management cluster environment"
	@echo "  destroy-regional                      - Destroy regional cluster environment"
	@echo ""
	@echo "🔧 Infrastructure Only:"
	@echo "  apply-infra-management                - Apply only management cluster infrastructure"
	@echo "  apply-infra-regional                  - Apply only regional cluster infrastructure"
	@echo ""
	@echo "📡 Maestro Agent IoT Provisioning:"
	@echo "  provision-maestro-agent-iot-regional   - Provision IoT cert in regional account"
	@echo "  cleanup-maestro-agent-iot              - Cleanup IoT resources before re-provisioning"
	@echo ""
	@echo "🐳 Platform Image:"
	@echo "  build-platform-image                  - Build and push platform image to ECR"
	@echo ""
	@echo "🛠️  Terraform Utilities:"
	@echo "  terraform-fmt                         - Format all Terraform files"
	@echo "  terraform-upgrade                     - Upgrade provider versions"
	@echo "  terraform-output-management           - Get Terraform output for Management Cluster"
	@echo "  terraform-output-regional             - Get Terraform output for Regional Cluster"
	@echo ""
	@echo "🧪 Validation & Testing:"
	@echo "  terraform-validate                    - Check formatting and validate all Terraform configs"
	@echo "  helm-lint                             - Lint all Helm charts"
	@echo "  check-rendered-files                  - Verify deploy/ is up to date with config.yaml"
	@echo "  test-e2e                              - Run end-to-end tests"
	@echo ""
	@echo "🔄 Ephemeral Environments (shared dev accounts):"
	@echo "  ephemeral-provision                   - Provision an ephemeral environment"
	@echo "  ephemeral-teardown                    - Tear down an ephemeral environment"
	@echo "  ephemeral-resync                      - Resync an ephemeral environment's CI branch"
	@echo "  ephemeral-list                        - List ephemeral environments"
	@echo ""
	@echo "  help                                  - Show this help message"

# Discover all directories containing Terraform files (excluding .terraform subdirectories)
TERRAFORM_DIRS := $(shell find ./terraform -name "*.tf" -type f -not -path "*/.terraform/*" | xargs dirname | sort -u)

# Root configurations only (terraform/config/*) — used for validate, which can't run on
# standalone child modules that declare provider configuration_aliases.
TERRAFORM_ROOT_DIRS := $(shell find ./terraform/config -name "*.tf" -type f -not -path "*/.terraform/*" | xargs dirname | sort -u)

# Format all Terraform files
terraform-fmt:
	@echo "🔧 Formatting Terraform files..."
	@for dir in $(TERRAFORM_DIRS); do \
		echo "   Formatting $$dir"; \
		terraform -chdir=$$dir fmt -recursive; \
	done
	@echo "✅ Terraform formatting complete"

# Upgrade provider versions in all Terraform configurations
terraform-upgrade:
	@echo "🔧 Upgrading Terraform provider versions..."
	@for dir in $(TERRAFORM_DIRS); do \
		echo "   Upgrading $$dir"; \
		terraform -chdir=$$dir init -upgrade -backend=false; \
	done
	@echo "✅ Terraform upgrade complete"

terraform-output-management:
	@cd terraform/config/management-cluster && terraform output -json

terraform-output-regional:
	@cd terraform/config/regional-cluster && terraform output -json

# =============================================================================
# Central Account Bootstrap
# =============================================================================

# Bootstrap central AWS account with Terraform state and pipeline infrastructure
# Usage: make bootstrap-central-account GITHUB_REPOSITORY=owner/repo [GITHUB_BRANCH=branch] [TARGET_ENVIRONMENT=env]
# Or: make bootstrap-central-account (uses defaults)
bootstrap-central-account:
	@if [ -n "$(GITHUB_REPOSITORY)" ]; then \
		scripts/bootstrap-central-account.sh "$(GITHUB_REPOSITORY)" "$(GITHUB_BRANCH)" "$(TARGET_ENVIRONMENT)"; \
	else \
		scripts/bootstrap-central-account.sh; \
	fi

# =============================================================================
# Cluster Provisioning/Deprovisioning Targets
# =============================================================================

# Provision complete management cluster (infrastructure + ArgoCD)
provision-management:
	@echo "🚀 Provisioning management cluster..."
	@echo ""
	@scripts/dev/validate-argocd-config.sh management-cluster
	@echo ""
	@echo "📍 Terraform Directory: terraform/config/management-cluster"
	@echo "🔑 AWS Caller Identity:" && aws sts get-caller-identity
	@echo ""
	@read -p "Do you want to proceed? [y/N]: " confirm && \
		if [ "$$confirm" != "y" ] && [ "$$confirm" != "Y" ]; then \
			echo "❌ Operation cancelled."; \
			exit 1; \
		fi
	@echo ""
	@cd terraform/config/management-cluster && \
		terraform init && terraform apply
	@echo ""
	@echo "Building platform image (if needed)..."
	@scripts/build-platform-image.sh
	@echo ""
	@echo "Bootstrapping argocd..."
	scripts/bootstrap-argocd.sh management-cluster

# Provision complete regional cluster (infrastructure + ArgoCD)
provision-regional:
	@echo "🚀 Provisioning regional cluster..."
	@echo ""
	@scripts/dev/validate-argocd-config.sh regional-cluster
	@echo ""
	@echo "📍 Terraform Directory: terraform/config/regional-cluster"
	@echo "🔑 AWS Caller Identity:" && aws sts get-caller-identity
	@echo ""
	@read -p "Do you want to proceed? [y/N]: " confirm && \
		if [ "$$confirm" != "y" ] && [ "$$confirm" != "Y" ]; then \
			echo "❌ Operation cancelled."; \
			exit 1; \
		fi
	@echo ""
	@cd terraform/config/regional-cluster && \
		terraform init && terraform apply
	@echo ""
	@echo "Building platform image (if needed)..."
	@scripts/build-platform-image.sh
	@echo ""
	@echo "Bootstrapping argocd..."
	@scripts/bootstrap-argocd.sh regional-cluster

# Guard target to validate Terraform state variables
require-tf-state-vars:
	@if [ -z "$${TF_STATE_BUCKET}" ]; then \
		echo "❌ ERROR: TF_STATE_BUCKET environment variable is not set"; \
		echo "   This variable is required for Terraform remote state configuration"; \
		exit 1; \
	fi
	@if [ -z "$${TF_STATE_KEY}" ]; then \
		echo "❌ ERROR: TF_STATE_KEY environment variable is not set"; \
		echo "   This variable is required for Terraform remote state configuration"; \
		exit 1; \
	fi
	@if [ -z "$${TF_STATE_REGION}" ]; then \
		echo "❌ ERROR: TF_STATE_REGION environment variable is not set"; \
		echo "   This variable is required for Terraform remote state configuration"; \
		exit 1; \
	fi

# Pipeline provision for regional cluster (Non-interactive)
pipeline-provision-regional: require-tf-state-vars
	@echo "🚀 Provisioning regional cluster infrastructure (Pipeline Mode)..."
	@echo "📍 Terraform Directory: terraform/config/regional-cluster"
	@cd terraform/config/regional-cluster && \
		terraform init -reconfigure \
			-backend-config="bucket=$${TF_STATE_BUCKET}" \
			-backend-config="key=$${TF_STATE_KEY}" \
			-backend-config="region=$${TF_STATE_REGION}" \
			-backend-config="use_lockfile=true" && \
		terraform apply -auto-approve


# Pipeline provision for management cluster (Non-interactive)
pipeline-provision-management: require-tf-state-vars
	@echo "🚀 Provisioning management cluster infrastructure (Pipeline Mode)..."
	@echo "📍 Terraform Directory: terraform/config/management-cluster"
	@cd terraform/config/management-cluster && \
		terraform init -reconfigure \
			-backend-config="bucket=$${TF_STATE_BUCKET}" \
			-backend-config="key=$${TF_STATE_KEY}" \
			-backend-config="region=$${TF_STATE_REGION}" \
			-backend-config="use_lockfile=true" && \
		terraform apply -auto-approve

# Pipeline destroy for regional cluster (Non-interactive)
pipeline-destroy-regional: require-tf-state-vars
	@echo "🗑️  Destroying regional cluster infrastructure (Pipeline Mode)..."
	@echo "📍 Terraform Directory: terraform/config/regional-cluster"
	@cd terraform/config/regional-cluster && \
		terraform init -reconfigure \
			-backend-config="bucket=$${TF_STATE_BUCKET}" \
			-backend-config="key=$${TF_STATE_KEY}" \
			-backend-config="region=$${TF_STATE_REGION}" \
			-backend-config="use_lockfile=true" && \
		terraform destroy -auto-approve

# Pipeline destroy for management cluster (Non-interactive)
pipeline-destroy-management: require-tf-state-vars
	@echo "🗑️  Destroying management cluster infrastructure (Pipeline Mode)..."
	@echo "📍 Terraform Directory: terraform/config/management-cluster"
	@cd terraform/config/management-cluster && \
		terraform init -reconfigure \
			-backend-config="bucket=$${TF_STATE_BUCKET}" \
			-backend-config="key=$${TF_STATE_KEY}" \
			-backend-config="region=$${TF_STATE_REGION}" \
			-backend-config="use_lockfile=true" && \
		terraform destroy -auto-approve

# Destroy management cluster and all resources
destroy-management:
	@echo "🗑️  Destroying management cluster..."
	@echo ""
	@echo "📍 Terraform Directory: terraform/config/management-cluster"
	@echo "🔑 AWS Caller Identity:" && aws sts get-caller-identity
	@echo ""
	@read -p "Type 'destroy' to confirm deletion: " confirm && \
		if [ "$$confirm" != "destroy" ]; then \
			echo "❌ Operation cancelled. You must type exactly 'destroy' to proceed."; \
			exit 1; \
		fi
	@echo ""
	@cd terraform/config/management-cluster && \
		terraform init && terraform destroy

# Destroy regional cluster and all resources
destroy-regional:
	@echo "🗑️  Destroying regional cluster..."
	@echo ""
	@echo "📍 Terraform Directory: terraform/config/regional-cluster"
	@echo "🔑 AWS Caller Identity:" && aws sts get-caller-identity
	@echo ""
	@read -p "Type 'destroy' to confirm deletion: " confirm && \
		if [ "$$confirm" != "destroy" ]; then \
			echo "❌ Operation cancelled. You must type exactly 'destroy' to proceed."; \
			exit 1; \
		fi
	@echo ""
	@cd terraform/config/regional-cluster && \
		terraform init && terraform destroy

# =============================================================================
# Infrastructure Maintenance Targets
# =============================================================================

# Infrastructure-only deployment
apply-infra-management:
	@echo "🏗️  Applying management cluster infrastructure..."
	@echo ""
	@echo "📍 Terraform Directory: terraform/config/management-cluster"
	@echo ""
	@read -p "Do you want to proceed? [y/N]: " confirm && \
		if [ "$$confirm" != "y" ] && [ "$$confirm" != "Y" ]; then \
			echo "❌ Operation cancelled."; \
			exit 1; \
		fi
	@echo ""
	@cd terraform/config/management-cluster && \
		terraform init && terraform apply

apply-infra-regional:
	@echo "🏗️  Applying regional cluster infrastructure..."
	@echo ""
	@echo "📍 Terraform Directory: terraform/config/regional-cluster"
	@echo ""
	@read -p "Do you want to proceed? [y/N]: " confirm && \
		if [ "$$confirm" != "y" ] && [ "$$confirm" != "Y" ]; then \
			echo "❌ Operation cancelled."; \
			exit 1; \
		fi
	@echo ""
	@cd terraform/config/regional-cluster && \
		terraform init && terraform apply

# Provision IoT resources in regional account (Step 1)
provision-maestro-agent-iot-regional:
	@if [ -z "$(MGMT_TFVARS)" ]; then \
		echo "❌ Error: MGMT_TFVARS not set"; \
		echo ""; \
		echo "Usage: make provision-maestro-agent-iot-regional MGMT_TFVARS=<path-to-tfvars>"; \
		echo ""; \
		echo "Example:"; \
		echo "  make provision-maestro-agent-iot-regional MGMT_TFVARS=terraform/config/management-cluster/terraform.tfvars"; \
		echo ""; \
		echo "⚠️  Ensure you are authenticated with REGIONAL AWS account credentials!"; \
		exit 1; \
	fi
	@./scripts/provision-maestro-agent-iot-regional.sh $(MGMT_TFVARS)

# Cleanup IoT resources (run before re-provisioning)
cleanup-maestro-agent-iot:
	@if [ -z "$(MGMT_TFVARS)" ]; then \
		echo "❌ Error: MGMT_TFVARS not set"; \
		echo ""; \
		echo "Usage: make cleanup-maestro-agent-iot MGMT_TFVARS=<path-to-tfvars>"; \
		echo ""; \
		echo "Example:"; \
		echo "  make cleanup-maestro-agent-iot MGMT_TFVARS=terraform/config/management-cluster/terraform.tfvars"; \
		echo ""; \
		echo "⚠️  Run this in the same AWS account where IoT resources were created"; \
		exit 1; \
	fi
	@./scripts/cleanup-maestro-agent-iot.sh $(MGMT_TFVARS)

# =============================================================================
# Platform Image
# =============================================================================

# Build and push the platform container image to ECR (uses current AWS credentials)
build-platform-image:
	@scripts/build-platform-image.sh

# =============================================================================
# Validation & Testing Targets
# =============================================================================

# Initialize root Terraform configurations (no backend)
terraform-init:
	@echo "🔧 Initializing Terraform configurations..."
	@for dir in $(TERRAFORM_ROOT_DIRS); do \
		echo "   Initializing $$dir"; \
		if ! terraform -chdir=$$dir init -backend=false; then \
			echo "   ❌ Init failed in $$dir"; \
			exit 1; \
		fi; \
	done
	@echo "✅ Terraform initialization complete"

# Check formatting and validate all Terraform configurations
# Note: fmt runs on all dirs (modules + configs), but validate only runs on
# root configs because child modules with provider configuration_aliases
# cannot be validated in isolation.
terraform-validate: terraform-init
	@echo "🔍 Checking Terraform formatting..."
	@failed=0; \
	for dir in $(TERRAFORM_DIRS); do \
		echo "   Checking formatting in $$dir"; \
		if ! terraform -chdir=$$dir fmt -check -recursive; then \
			echo "   ❌ Formatting check failed in $$dir"; \
			failed=1; \
		fi; \
	done; \
	if [ "$$failed" -ne 0 ]; then \
		echo "❌ Terraform formatting check failed for one or more directories"; \
		echo "   Run 'make terraform-fmt' to fix formatting."; \
		exit 1; \
	fi
	@echo "🔍 Validating Terraform configurations..."
	@failed=0; \
	for dir in $(TERRAFORM_ROOT_DIRS); do \
		echo "   Validating $$dir"; \
		if ! terraform -chdir=$$dir validate; then \
			echo "   ❌ Validation failed in $$dir"; \
			failed=1; \
		fi; \
	done; \
	if [ "$$failed" -ne 0 ]; then \
		echo "❌ Terraform validation failed for one or more directories"; \
		exit 1; \
	fi
	@echo "✅ Terraform validation complete"

# Lint all Helm charts under argocd/config/
# Global values (aws_region, environment, cluster_type) are injected by the
# ApplicationSet at deploy time, so we supply stubs here for linting.
HELM_LINT_SET := --set global.aws_region=us-east-1 --set global.environment=lint --set global.cluster_type=lint
helm-lint:
	@echo "🔍 Linting Helm charts..."
	@failed=false; \
	for chart_dir in $$(find argocd/config -name "Chart.yaml" -exec dirname {} \; | sort); do \
		echo "   Linting $$chart_dir"; \
		if ! helm lint $$chart_dir $(HELM_LINT_SET); then \
			failed=true; \
		fi; \
	done; \
	if [ "$$failed" = true ]; then \
		echo "❌ Helm lint failed for one or more charts"; \
		exit 1; \
	fi
	@echo "✅ Helm lint complete"

# Verify rendered files in deploy/ are up to date with config.yaml
check-rendered-files:
	@echo "🔍 Rendering deploy/ from config.yaml..."
	@uv run --no-cache scripts/render.py
	@echo "Checking for uncommitted changes in deploy/..."
	@if ! git diff --exit-code deploy/; then \
		echo ""; \
		echo "❌ Rendered files in deploy/ are out of date."; \
		echo "   Run 'uv run scripts/render.py' and commit the results."; \
		exit 1; \
	fi
	@untracked=$$(git ls-files --others --exclude-standard deploy/); \
	if [ -n "$$untracked" ]; then \
		echo ""; \
		echo "❌ Untracked rendered files found in deploy/:"; \
		echo "$$untracked"; \
		echo "   Run 'uv run scripts/render.py' and 'git add' the new files."; \
		exit 1; \
	fi
	@echo "✅ Rendered files are up to date"

# =============================================================================
# Ephemeral Environments
# =============================================================================
# Provision/teardown ephemeral environments in shared dev AWS accounts from
# your local machine. Runs the ephemeral provider inside the CI container.

# Auto-detect container engine (podman preferred, falls back to docker)
CONTAINER_ENGINE ?= $(shell command -v podman 2>/dev/null || command -v docker 2>/dev/null)

EPHEMERAL_CI_IMAGE := rosa-regional-ci
EPHEMERAL_ENVS_FILE := .ephemeral-envs
VAULT_ADDR := https://vault.ci.openshift.org
VAULT_KV_MOUNT := kv
VAULT_SECRET_PATH := selfservice/cluster-secrets-rosa-regional-platform-int/ephemeral-shared-dev-creds
VAULT_CRED_KEYS := central_access_key central_secret_key central_assume_role_arn regional_access_key regional_secret_key management_access_key management_secret_key github_token

REPO ?= openshift-online/rosa-regional-platform
BRANCH ?= $(shell git rev-parse --abbrev-ref HEAD)
REGION ?= us-east-1

# Helper: update STATE for a BUILD_ID in .ephemeral-envs (portable, no sed -i)
# Usage: $(call update-state,BUILD_ID,NEW_STATE)
define update-state
grep -v '^$(1) ' $(EPHEMERAL_ENVS_FILE) > $(EPHEMERAL_ENVS_FILE).tmp; grep '^$(1) ' $(EPHEMERAL_ENVS_FILE) | sed 's/STATE=[^ ]*/STATE=$(2)/' >> $(EPHEMERAL_ENVS_FILE).tmp; mv $(EPHEMERAL_ENVS_FILE).tmp $(EPHEMERAL_ENVS_FILE)
endef

# Verify required tools are installed
ephemeral-preflight:
	@missing=""; \
	for tool in fzf vault git python3 uv; do \
		if ! command -v $$tool >/dev/null 2>&1; then \
			missing="$$missing $$tool"; \
		fi; \
	done; \
	if [ -z "$(CONTAINER_ENGINE)" ]; then \
		missing="$$missing podman/docker"; \
	fi; \
	if [ -n "$$missing" ]; then \
		echo "Missing required tools:$$missing"; \
		exit 1; \
	fi

# Build the CI container image if not already present
ephemeral-image: ephemeral-preflight
	@if [ -z "$(CONTAINER_ENGINE)" ]; then \
		echo "Error: No container engine found. Install podman or docker."; \
		exit 1; \
	fi
	@if ! $(CONTAINER_ENGINE) image inspect $(EPHEMERAL_CI_IMAGE) >/dev/null 2>&1; then \
		echo "Building CI image..."; \
		if ! build_output=$$($(CONTAINER_ENGINE) build -t $(EPHEMERAL_CI_IMAGE) -f ci/Containerfile ci 2>&1); then \
			echo "$$build_output"; \
			echo "Error: Failed to build CI image."; \
			exit 1; \
		fi; \
	fi

# Fetch credentials from Vault into shell variables and build container -e flags.
# Credentials never touch disk — they live only in shell process memory.
# Usage: $(fetch-creds) at the start of a recipe; use $$_CRED_FLAGS in container run.
define fetch-creds
echo "Fetching credentials from Vault (OIDC login)..."; _VAULT_TOKEN=$$(VAULT_ADDR=$(VAULT_ADDR) vault login -method=oidc -token-only 2>/dev/null) || { echo "Error: Vault OIDC login failed."; exit 1; }; _CRED_FLAGS=""; for _key in $(VAULT_CRED_KEYS); do _val=$$(VAULT_ADDR=$(VAULT_ADDR) VAULT_TOKEN=$$_VAULT_TOKEN vault kv get -mount=$(VAULT_KV_MOUNT) -field=$$_key $(VAULT_SECRET_PATH) 2>/dev/null) || { echo "Error: Failed to fetch credential '$$_key' from Vault."; exit 1; }; _ukey=$$(echo "$$_key" | tr 'a-z' 'A-Z'); _CRED_FLAGS="$$_CRED_FLAGS -e $$_ukey=$$_val"; done; echo "Credentials loaded (in-memory only)."
endef

# Provision an ephemeral environment
# Usage: make ephemeral-provision [REPO=owner/repo] [BRANCH=branch] [REGION=region] [BUILD_ID=id]
ephemeral-provision: ephemeral-image
	$(eval BUILD_ID ?= $(shell python3 -c "import uuid; print(uuid.uuid4().hex[:8])"))
	@# FZF remote + branch picker when BRANCH is not explicitly passed
	@_BRANCH="$(BRANCH)"; \
	_REPO="$(REPO)"; \
	if [ "$(origin BRANCH)" != "command line" ] && command -v fzf >/dev/null 2>&1; then \
		echo "Current branch: $(BRANCH)"; \
		echo "Select a remote to pick a branch from (or Esc to abort):"; \
		_remote=$$(git remote -v | grep '(fetch)' | awk '{printf "%-15s %s\n", $$1, $$2}' | \
			fzf --height=10 --header="Select remote:" | awk '{print $$1}') || \
			{ echo "Aborted."; exit 1; }; \
		_REPO=$$(git remote get-url $$_remote | sed 's|.*github\.com[:/]||; s|\.git$$||'); \
		echo "Fetching branches from $$_remote ($$_REPO)..."; \
		_BRANCH=$$(git ls-remote --heads $$_remote 2>/dev/null | sed 's|.*refs/heads/||' | \
			fzf --height=20 --header="Select branch:") || \
			{ echo "Aborted."; exit 1; }; \
		echo "Selected branch: $$_BRANCH (from $$_remote)"; \
	fi; \
	$(fetch-creds); \
	echo "Provisioning ephemeral environment..."; \
	echo "  BUILD_ID:          $(BUILD_ID)"; \
	echo "  REPO:              $$_REPO"; \
	echo "  BRANCH:            $$_BRANCH"; \
	echo "  REGION:            $(REGION)"; \
	echo "  CONTAINER_ENGINE:  $(CONTAINER_ENGINE)"; \
	echo "  IMAGE:             $(EPHEMERAL_CI_IMAGE)"; \
	echo "$(BUILD_ID) REPO=$$_REPO BRANCH=$$_BRANCH REGION=$(REGION) STATE=provisioning CREATED=$$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> $(EPHEMERAL_ENVS_FILE); \
	$(CONTAINER_ENGINE) run --rm \
		$$_CRED_FLAGS \
		-v $(PWD):/workspace:ro \
		-w /workspace \
		-e BUILD_ID=$(BUILD_ID) \
		-e AWS_REGION=$(REGION) \
		$(EPHEMERAL_CI_IMAGE) \
		uv run --no-cache ci/ephemeral-provider/main.py --repo $$_REPO --branch $$_BRANCH --region $(REGION); \
	rc=$$?; \
	if [ $$rc -eq 0 ]; then \
		$(call update-state,$(BUILD_ID),ready); \
		echo ""; \
		echo "Environment recorded in $(EPHEMERAL_ENVS_FILE). To tear down:"; \
		echo "  make ephemeral-teardown BUILD_ID=$(BUILD_ID)"; \
	else \
		$(call update-state,$(BUILD_ID),provisioning-failed); \
		echo "Provisioning failed. State updated to provisioning-failed."; \
		exit $$rc; \
	fi

# Tear down an ephemeral environment
# Usage: make ephemeral-teardown [BUILD_ID=<id>]
ephemeral-teardown: ephemeral-image
	@if [ "$(origin BUILD_ID)" = "command line" ]; then \
		_BUILD_ID="$(BUILD_ID)"; \
	else \
		if [ ! -f $(EPHEMERAL_ENVS_FILE) ] || [ ! -s $(EPHEMERAL_ENVS_FILE) ]; then \
			echo "No environments found in $(EPHEMERAL_ENVS_FILE)."; exit 1; \
		fi; \
		candidates=$$(grep -v 'STATE=deprovisioned ' $(EPHEMERAL_ENVS_FILE) || true); \
		if [ -z "$$candidates" ]; then \
			echo "No active environments found."; exit 1; \
		fi; \
		_line=$$(echo "$$candidates" | fzf --height=20 --header="Select environment to tear down:") || \
			{ echo "Aborted."; exit 1; }; \
		_BUILD_ID=$$(echo "$$_line" | awk '{print $$1}'); \
	fi; \
	_line=$$(grep "^$$_BUILD_ID " $(EPHEMERAL_ENVS_FILE) 2>/dev/null) || \
		{ echo "BUILD_ID $$_BUILD_ID not found in $(EPHEMERAL_ENVS_FILE)."; exit 1; }; \
	_REPO=$$(echo "$$_line" | sed -n 's/.*REPO=\([^ ]*\).*/\1/p'); \
	_BRANCH=$$(echo "$$_line" | sed -n 's/.*BRANCH=\([^ ]*\).*/\1/p'); \
	_REGION=$$(echo "$$_line" | sed -n 's/.*REGION=\([^ ]*\).*/\1/p'); \
	$(fetch-creds); \
	echo "Tearing down ephemeral environment..."; \
	echo "  BUILD_ID:          $$_BUILD_ID"; \
	echo "  REPO:              $$_REPO"; \
	echo "  BRANCH:            $$_BRANCH"; \
	echo "  REGION:            $$_REGION"; \
	echo "  CONTAINER_ENGINE:  $(CONTAINER_ENGINE)"; \
	echo "  IMAGE:             $(EPHEMERAL_CI_IMAGE)"; \
	grep -v "^$$_BUILD_ID " $(EPHEMERAL_ENVS_FILE) > $(EPHEMERAL_ENVS_FILE).tmp; grep "^$$_BUILD_ID " $(EPHEMERAL_ENVS_FILE) | sed 's/STATE=[^ ]*/STATE=deprovisioning/' >> $(EPHEMERAL_ENVS_FILE).tmp; mv $(EPHEMERAL_ENVS_FILE).tmp $(EPHEMERAL_ENVS_FILE); \
	$(CONTAINER_ENGINE) run --rm \
		$$_CRED_FLAGS \
		-v $(PWD):/workspace:ro \
		-w /workspace \
		-e BUILD_ID=$$_BUILD_ID \
		-e AWS_REGION=$$_REGION \
		$(EPHEMERAL_CI_IMAGE) \
		uv run --no-cache ci/ephemeral-provider/main.py --teardown --repo $$_REPO --branch $$_BRANCH --region $$_REGION; \
	rc=$$?; \
	if [ $$rc -eq 0 ]; then \
		grep -v "^$$_BUILD_ID " $(EPHEMERAL_ENVS_FILE) > $(EPHEMERAL_ENVS_FILE).tmp; grep "^$$_BUILD_ID " $(EPHEMERAL_ENVS_FILE) | sed 's/STATE=[^ ]*/STATE=deprovisioned/' >> $(EPHEMERAL_ENVS_FILE).tmp; mv $(EPHEMERAL_ENVS_FILE).tmp $(EPHEMERAL_ENVS_FILE); \
		echo "Environment $$_BUILD_ID deprovisioned."; \
	else \
		grep -v "^$$_BUILD_ID " $(EPHEMERAL_ENVS_FILE) > $(EPHEMERAL_ENVS_FILE).tmp; grep "^$$_BUILD_ID " $(EPHEMERAL_ENVS_FILE) | sed 's/STATE=[^ ]*/STATE=deprovisioning-failed/' >> $(EPHEMERAL_ENVS_FILE).tmp; mv $(EPHEMERAL_ENVS_FILE).tmp $(EPHEMERAL_ENVS_FILE); \
		echo "Teardown failed. State updated to deprovisioning-failed."; \
		exit $$rc; \
	fi

# Resync an ephemeral environment's CI branch onto latest source branch
# Usage: make ephemeral-resync [BUILD_ID=<id>]
ephemeral-resync: ephemeral-image
	@if [ "$(origin BUILD_ID)" = "command line" ]; then \
		_BUILD_ID="$(BUILD_ID)"; \
	else \
		if [ ! -f $(EPHEMERAL_ENVS_FILE) ] || [ ! -s $(EPHEMERAL_ENVS_FILE) ]; then \
			echo "No environments found in $(EPHEMERAL_ENVS_FILE)."; exit 1; \
		fi; \
		candidates=$$(grep -v 'STATE=deprovisioned ' $(EPHEMERAL_ENVS_FILE) || true); \
		if [ -z "$$candidates" ]; then \
			echo "No active environments found."; exit 1; \
		fi; \
		_line=$$(echo "$$candidates" | fzf --height=20 --header="Select environment to resync:") || \
			{ echo "Aborted."; exit 1; }; \
		_BUILD_ID=$$(echo "$$_line" | awk '{print $$1}'); \
	fi; \
	_line=$$(grep "^$$_BUILD_ID " $(EPHEMERAL_ENVS_FILE) 2>/dev/null) || \
		{ echo "BUILD_ID $$_BUILD_ID not found in $(EPHEMERAL_ENVS_FILE)."; exit 1; }; \
	_REPO=$$(echo "$$_line" | sed -n 's/.*REPO=\([^ ]*\).*/\1/p'); \
	_BRANCH=$$(echo "$$_line" | sed -n 's/.*BRANCH=\([^ ]*\).*/\1/p'); \
	_REGION=$$(echo "$$_line" | sed -n 's/.*REGION=\([^ ]*\).*/\1/p'); \
	$(fetch-creds); \
	echo "Resyncing ephemeral environment CI branch..."; \
	echo "  BUILD_ID:          $$_BUILD_ID"; \
	echo "  REPO:              $$_REPO"; \
	echo "  BRANCH:            $$_BRANCH"; \
	echo "  CONTAINER_ENGINE:  $(CONTAINER_ENGINE)"; \
	echo "  IMAGE:             $(EPHEMERAL_CI_IMAGE)"; \
	$(CONTAINER_ENGINE) run --rm \
		$$_CRED_FLAGS \
		-v $(PWD):/workspace:ro \
		-w /workspace \
		-e BUILD_ID=$$_BUILD_ID \
		$(EPHEMERAL_CI_IMAGE) \
		uv run --no-cache ci/ephemeral-provider/main.py --resync --repo $$_REPO --branch $$_BRANCH --region $$_REGION; \
	rc=$$?; \
	if [ $$rc -ne 0 ]; then \
		echo "Resync failed."; \
		exit $$rc; \
	fi

# List ephemeral environments
ephemeral-list:
	@if [ -f $(EPHEMERAL_ENVS_FILE) ] && [ -s $(EPHEMERAL_ENVS_FILE) ]; then \
		echo "Ephemeral environments:"; \
		echo ""; \
		printf "%-12s %-45s %-25s %-12s %-22s %s\n" "BUILD_ID" "REPO" "BRANCH" "REGION" "STATE" "CREATED"; \
		echo "------------ --------------------------------------------- ------------------------- ------------ ---------------------- --------------------"; \
		while IFS= read -r line; do \
			build_id=$$(echo "$$line" | awk '{print $$1}'); \
			repo=$$(echo "$$line" | sed -n 's/.*REPO=\([^ ]*\).*/\1/p'); \
			branch=$$(echo "$$line" | sed -n 's/.*BRANCH=\([^ ]*\).*/\1/p'); \
			region=$$(echo "$$line" | sed -n 's/.*REGION=\([^ ]*\).*/\1/p'); \
			state=$$(echo "$$line" | sed -n 's/.*STATE=\([^ ]*\).*/\1/p'); \
			created=$$(echo "$$line" | sed -n 's/.*CREATED=\([^ ]*\).*/\1/p'); \
			printf "%-12s %-45s %-25s %-12s %-22s %s\n" "$$build_id" "$$repo" "$$branch" "$$region" "$$state" "$$created"; \
		done < $(EPHEMERAL_ENVS_FILE); \
		echo ""; \
		echo "To clear list: rm $(EPHEMERAL_ENVS_FILE)"; \
	else \
		echo "No ephemeral environments."; \
	fi

