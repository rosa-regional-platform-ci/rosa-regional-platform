.PHONY: help terraform-fmt terraform-init terraform-validate terraform-upgrade terraform-output-management terraform-output-regional provision-management provision-regional apply-infra-management apply-infra-regional provision-maestro-agent-iot-regional cleanup-maestro-agent-iot destroy-management destroy-regional build-platform-image test-e2e helm-lint check-rendered-files

# Default target
help:
	@echo "🚀 Cluster Provisioning / Deprovisioning:"
	@echo "  provision-management             - Provision management cluster environment (infra & argocd bootstrap)"
	@echo "  provision-regional               - Provision regional cluster environment (infra & argocd bootstrap)"
	@echo "  destroy-management               - Destroy management cluster environment"
	@echo "  destroy-regional                 - Destroy regional cluster environment"
	@echo ""
	@echo "🔧 Infrastructure Only:"
	@echo "  apply-infra-management                - Apply only management cluster infrastructure"
	@echo "  apply-infra-regional                  - Apply only regional cluster infrastructure"
	@echo ""
	@echo "📡 Maestro Agent IoT Provisioning:"
	@echo "  provision-maestro-agent-iot-regional   - Provision IoT cert in regional account (state persisted)"
	@echo "  cleanup-maestro-agent-iot              - Cleanup IoT resources before re-provisioning"
	@echo ""
	@echo "🐳 Platform Image:"
	@echo "  build-platform-image             - Build and push platform image to ECR"
	@echo ""
	@echo "🛠️  Terraform Utilities:"
	@echo "  terraform-fmt                    - Format all Terraform files"
	@echo "  terraform-upgrade                - Upgrade provider versions"
	@echo "  terraform-output-management      - Get the Terraform output for the Management Cluster"
	@echo "  terraform-output-regional        - Get the Terraform output for the Regional Cluster"
	@echo ""
	@echo "🧪 Validation & Testing:"
	@echo "  terraform-validate               - Check formatting and validate all Terraform configs"
	@echo "  helm-lint                        - Lint all Helm charts"
	@echo "  check-rendered-files             - Verify deploy/ is up to date with config.yaml"
	@echo "  test-e2e                         - Run end-to-end tests"
	@echo ""
	@echo "  help                             - Show this help message"

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

