#!/usr/bin/env bash
# Provision or destroy Regional Cluster infrastructure.
# Called from: terraform/config/pipeline-regional-cluster/buildspec-provision-infra.yml
set -euo pipefail

echo "=========================================="
echo "Provisioning Regional Cluster Infrastructure"
echo "Build #${CODEBUILD_BUILD_NUMBER:-?} | ${CODEBUILD_BUILD_ID:-unknown}"
echo "=========================================="

# Pre-flight setup (validates env vars, inits account helpers)
source scripts/pipeline-common/setup-apply-preflight.sh

# Load terraform variables from deploy/ JSON
source scripts/pipeline-common/load-deploy-config.sh regional

# Save central credentials as a named AWS profile so Terraform's aws.central
# provider can access the central account after use_mc_account switches
# ambient creds to the target account.
aws configure set aws_access_key_id     "$_CENTRAL_AWS_ACCESS_KEY_ID"     --profile central
aws configure set aws_secret_access_key "$_CENTRAL_AWS_SECRET_ACCESS_KEY" --profile central
aws configure set aws_session_token     "$_CENTRAL_AWS_SESSION_TOKEN"     --profile central
aws configure set region                "${TARGET_REGION}"                --profile central

# Assume target account role for both state and resource operations
use_mc_account
echo ""

echo "Deploying to account: ${TARGET_ACCOUNT_ID}"
echo "  Region: ${TARGET_REGION}"
echo "  Regional ID: ${TF_VAR_regional_id}"
echo ""

# Configure Terraform backend (state in target account)
export TF_STATE_BUCKET="terraform-state-${TARGET_ACCOUNT_ID}"
export TF_STATE_KEY="regional-cluster/${TF_VAR_regional_id}.tfstate"
export TF_STATE_REGION="${TARGET_REGION}"

echo "Terraform backend:"
echo "  Bucket: $TF_STATE_BUCKET (target account: $TARGET_ACCOUNT_ID)"
echo "  Key: $TF_STATE_KEY"
echo "  Region: $TF_STATE_REGION"
echo ""

# Runtime TF vars from CodeBuild (not in deploy config)
export TF_VAR_central_aws_profile="central"
export TF_VAR_repository_url="${REPOSITORY_URL}"
export TF_VAR_repository_branch="${REPOSITORY_BRANCH:-main}"
export TF_VAR_api_additional_allowed_accounts="${TARGET_ACCOUNT_ID}"

# Set container image for ECS tasks (bastion and bootstrap)
if [ -z "${PLATFORM_IMAGE:-}" ]; then
    echo "ERROR: PLATFORM_IMAGE is not set or empty; cannot set TF_VAR_container_image" >&2
    exit 1
fi
export TF_VAR_container_image="${PLATFORM_IMAGE}"

# Optional DNS hosted zone ID (provisioned by provision-pipelines.sh)
if [ -n "${ENVIRONMENT_HOSTED_ZONE_ID:-}" ]; then
    export TF_VAR_environment_hosted_zone_id="${ENVIRONMENT_HOSTED_ZONE_ID}"
fi

echo "Terraform variables (from deploy config + runtime):"
echo "  Region: $TF_VAR_region"
echo "  App Code: $TF_VAR_app_code"
echo "  Service Phase: $TF_VAR_service_phase"
echo "  Cost Center: $TF_VAR_cost_center"
echo "  Repository URL: $TF_VAR_repository_url"
echo "  Repository Branch: $TF_VAR_repository_branch"
echo "  API Additional Allowed Accounts: $TF_VAR_api_additional_allowed_accounts"
echo "  Enable Bastion: $TF_VAR_enable_bastion"
echo "  Environment Domain: ${TF_VAR_environment_domain:-<not set>}"
echo "  Environment Hosted Zone ID: ${TF_VAR_environment_hosted_zone_id:-<not set>}"
echo "  Regional ID: $TF_VAR_regional_id"
echo "  Environment: $TF_VAR_environment"
echo "  Sector: $TF_VAR_sector"
echo ""

# Export required environment variables for Makefile target
export ENVIRONMENT="${ENVIRONMENT:-staging}"

# Read delete flag from config (GitOps-driven deletion)
DELETE_FLAG=$(jq -r '.delete // false' "$DEPLOY_CONFIG_FILE")
# Manual override: IS_DESTROY pipeline variable takes precedence
[ "${IS_DESTROY:-false}" == "true" ] && DELETE_FLAG="true"

echo ""
if [ "${DELETE_FLAG}" == "true" ]; then
    echo ">>> MODE: TEARDOWN <<<"
else
    echo ">>> MODE: PROVISION <<<"
fi
echo ""

if [ "${DELETE_FLAG}" == "true" ]; then
    make pipeline-destroy-regional
else
    make pipeline-provision-regional
fi
