.PHONY: help terraform-fmt terraform-init terraform-validate terraform-upgrade terraform-output-management terraform-output-regional helm-lint check-rendered-files ephemeral-provision ephemeral-teardown ephemeral-resync ephemeral-list ephemeral-shell ephemeral-bastion-rc ephemeral-bastion-mc ephemeral-port-forward-rc ephemeral-port-forward-mc ephemeral-port-forward-rc-all ephemeral-port-forward-mc-all ephemeral-e2e ephemeral-collect-logs int-shell int-bastion-rc int-bastion-mc int-port-forward-rc int-port-forward-mc int-port-forward-rc-all int-port-forward-mc-all int-e2e int-collect-logs check-docs pre-push

# Default target
help:
	@echo "🛠️ Terraform Utilities:"
	@echo "  terraform-fmt                         - Format all Terraform files"
	@echo "  terraform-upgrade                     - Upgrade provider versions"
	@echo "  terraform-output-management           - Get Terraform output for Management Cluster"
	@echo "  terraform-output-regional             - Get Terraform output for Regional Cluster"
	@echo ""
	@echo "🧪 Validation & Testing:"
	@echo "  pre-push                              - Run all CI validation checks (parallel)"
	@echo "  terraform-validate                    - Check formatting and validate all Terraform configs"
	@echo "  helm-lint                             - Lint all Helm charts"
	@echo "  check-rendered-files                  - Verify deploy/ is up to date with config.yaml"
	@echo "  check-docs                            - Check documentation formatting"
	@echo ""
	@echo "🔄 Ephemeral Environments (dev) — Lifecycle:"
	@echo "  ephemeral-provision                   - Provision an ephemeral environment"
	@echo "  ephemeral-teardown                    - Tear down an ephemeral environment"
	@echo "  ephemeral-resync                      - Resync an ephemeral environment to your branch"
	@echo "  ephemeral-list                        - List ephemeral environments"
	@echo ""
	@echo "🔧 Ephemeral Environments (dev) — Interacting:"
	@echo "  ephemeral-shell                       - Interactive shell for Platform API access"
	@echo "  ephemeral-bastion-rc                  - Connect to RC bastion in an ephemeral env"
	@echo "  ephemeral-bastion-mc                  - Connect to MC bastion in an ephemeral env"
	@echo "  ephemeral-port-forward-rc             - Create a port-forward session to RC service in an ephemeral env"
	@echo "  ephemeral-port-forward-mc             - Create a port-forward session to MC service in an ephemeral env"
	@echo "  ephemeral-port-forward-rc-all         - Automatically port forward all services for an RC in an ephemeral env"
	@echo "  ephemeral-port-forward-mc-all         - Automatically port forward all services for an MC in an ephemeral env"
	@echo "  ephemeral-e2e                         - Run e2e tests against an ephemeral env"
	@echo "  ephemeral-collect-logs                - Collect kubernetes logs from an ephemeral env (CLUSTER=rc|mc, default: both)"
	@echo ""
	@echo "🔧 Integration Environment — Interacting:"
	@echo "  int-shell                             - Interactive shell for Platform API access"
	@echo "  int-bastion-rc                        - Connect to RC bastion in int env"
	@echo "  int-bastion-mc                        - Connect to MC bastion in int env"
	@echo "  int-port-forward-rc                   - Create a port-forward session to RC service in int env"
	@echo "  int-port-forward-mc                   - Create a port-forward session to MC service in int env"
	@echo "  int-port-forward-rc-all               - Automatically port forward all services for RC in int env"
	@echo "  int-port-forward-mc-all               - Automatically port forward all services for MC in int env"
	@echo "  int-e2e                               - Run e2e tests against int env"
	@echo "  int-collect-logs                      - Collect kubernetes logs from int env (CLUSTER=rc|mc, default: both)"
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
	@echo "$(TERRAFORM_DIRS)" | tr ' ' '\n' | xargs -P 8 -I{} sh -c ' \
		echo "   Formatting $$1"; \
		terraform -chdir=$$1 fmt -recursive \
	' _ {}
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
# Validation & Testing Targets
# =============================================================================

# Initialize root Terraform configurations (no backend)
terraform-init:
	@echo "🔧 Initializing Terraform configurations..."
	@echo "$(TERRAFORM_ROOT_DIRS)" | tr ' ' '\n' | xargs -P 1 -I{} sh -c ' \
		echo "   Initializing $$1"; \
		if ! terraform -chdir=$$1 init -backend=false; then \
			echo "   ❌ Init failed in $$1"; \
			exit 1; \
		fi \
	' _ {} || exit 1
	@echo "✅ Terraform initialization complete"

# Check formatting and validate all Terraform configurations
# Note: fmt runs on all dirs (modules + configs), but validate only runs on
# root configs because child modules with provider configuration_aliases
# cannot be validated in isolation.
terraform-validate: terraform-init
	@echo "🔍 Checking Terraform formatting..."
	@echo "$(TERRAFORM_DIRS)" | tr ' ' '\n' | xargs -P 8 -I{} sh -c ' \
		echo "   Checking formatting in $$1"; \
		if ! terraform -chdir=$$1 fmt -check -recursive; then \
			echo "   ❌ Formatting check failed in $$1"; \
			exit 1; \
		fi \
	' _ {} || { echo "❌ Terraform formatting check failed for one or more directories"; \
		echo "   Run '\''make terraform-fmt'\'' to fix formatting."; \
		exit 1; }
	@echo "🔍 Validating Terraform configurations..."
	@echo "$(TERRAFORM_ROOT_DIRS)" | tr ' ' '\n' | xargs -P 2 -I{} sh -c ' \
		echo "   Validating $$1"; \
		if ! terraform -chdir=$$1 validate; then \
			echo "   ❌ Validation failed in $$1"; \
			exit 1; \
		fi \
	' _ {} || { echo "❌ Terraform validation failed for one or more directories"; \
		exit 1; }
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
	@echo "🔍 Checking config documentation..."
	@uv run --no-cache scripts/render.py --check-docs

# Check documentation formatting with prettier
check-docs:
	@echo "🔍 Checking documentation formatting..."
	@npx --no-install prettier --check '**/*.md'
	@echo "✅ Documentation formatting check complete"

# Run all CI validation checks in parallel
pre-push:
	@echo "🚀 Running all CI validation checks..."
	@echo ""
	@echo "Formatting Terraform files..."
	@$(MAKE) terraform-fmt
	@echo ""
	@$(MAKE) -j4 check-docs check-rendered-files helm-lint terraform-validate
	@echo ""
	@echo "✅ All pre-push checks passed!"

# =============================================================================
# Ephemeral Environments
# =============================================================================
# Thin wrappers around scripts/dev/ephemeral-env.sh.
# See docs/development-environment.md for full usage guide.

REPO   ?= openshift-online/rosa-regional-platform
BRANCH ?= $(shell git rev-parse --abbrev-ref HEAD)

ephemeral-provision:
	@ID="$(ID)" REPO="$(REPO)" BRANCH="$(if $(filter command line,$(origin BRANCH)),$(BRANCH),)" \
		./scripts/dev/ephemeral-env.sh provision

ephemeral-teardown:
	@ID="$(ID)" ./scripts/dev/ephemeral-env.sh teardown

ephemeral-resync:
	@ID="$(ID)" ./scripts/dev/ephemeral-env.sh resync

ephemeral-list:
	@./scripts/dev/ephemeral-env.sh list

ephemeral-shell:
	@ID="$(ID)" ./scripts/dev/ephemeral-env.sh shell

ephemeral-bastion-rc:
	@ID="$(ID)" ./scripts/dev/ephemeral-env.sh bastion --cluster-type regional

ephemeral-bastion-mc:
	@ID="$(ID)" ./scripts/dev/ephemeral-env.sh bastion --cluster-type management

ephemeral-port-forward-rc:
	@ID="$(ID)" ./scripts/dev/ephemeral-env.sh port-forward --cluster-type regional

ephemeral-port-forward-mc:
	@ID="$(ID)" ./scripts/dev/ephemeral-env.sh port-forward --cluster-type management

ephemeral-port-forward-rc-all:
	@ID="$(ID)" ./scripts/dev/ephemeral-env.sh port-forward --cluster-type regional --all

ephemeral-port-forward-mc-all:
	@ID="$(ID)" ./scripts/dev/ephemeral-env.sh port-forward --cluster-type management --all

ephemeral-e2e:
	@ID="$(ID)" E2E_REF="$(or $(E2E_REF),main)" E2E_REPO="$(E2E_REPO)" ./scripts/dev/ephemeral-env.sh e2e

ephemeral-collect-logs:
	@ID="$(ID)" ./scripts/dev/ephemeral-env.sh collect-logs $(CLUSTER)

# =============================================================================
# Integration Environment
# =============================================================================
# Thin wrappers around scripts/dev/int-env.sh.
# Uses AWS profiles with SAML auth (via rosa-regional-platform-internal).

int-shell:
	@./scripts/dev/int-env.sh shell

int-bastion-rc:
	@./scripts/dev/int-env.sh bastion --cluster-type regional

int-bastion-mc:
	@./scripts/dev/int-env.sh bastion --cluster-type management

int-port-forward-rc:
	@./scripts/dev/int-env.sh port-forward --cluster-type regional

int-port-forward-mc:
	@./scripts/dev/int-env.sh port-forward --cluster-type management

int-port-forward-rc-all:
	@./scripts/dev/int-env.sh port-forward --cluster-type regional --all

int-port-forward-mc-all:
	@./scripts/dev/int-env.sh port-forward --cluster-type management --all

int-e2e:
	@E2E_REF="$(or $(E2E_REF),main)" E2E_REPO="$(E2E_REPO)" ./scripts/dev/int-env.sh e2e

int-collect-logs:
	@./scripts/dev/int-env.sh collect-logs $(CLUSTER)
