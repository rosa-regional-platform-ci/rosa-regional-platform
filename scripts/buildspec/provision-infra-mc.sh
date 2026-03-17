#!/usr/bin/env bash
# Provision or destroy Management Cluster infrastructure.
# Called from: terraform/config/pipeline-management-cluster/buildspec-provision-infra.yml
set -euo pipefail

echo "=========================================="
echo "Provisioning Management Cluster Infrastructure"
echo "Build #${CODEBUILD_BUILD_NUMBER:-?} | ${CODEBUILD_BUILD_ID:-unknown}"
echo "=========================================="

# Pre-flight setup (validates env vars, inits account helpers)
source scripts/pipeline-common/setup-apply-preflight.sh

# Load terraform variables from deploy/ JSON
source scripts/pipeline-common/load-deploy-config.sh management

echo "Deploying to account: ${TARGET_ACCOUNT_ID}"
echo "  Region: ${TARGET_REGION}"
echo "  Management ID: ${MANAGEMENT_ID}"
echo ""

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

# =====================================================================
# Phase 1: Read IoT cert/config outputs from RC account state
# (skipped on destroy — IoT resources already cleaned up by Mint-IoT stage)
# =====================================================================
if [ "${DELETE_FLAG}" == "true" ]; then
    # Terraform still evaluates file() during destroy; provide empty placeholders.
    # (Can't use /dev/null — the cleanup line below would rm it in the container.)
    export TF_VAR_maestro_agent_cert_file=$(mktemp)
    export TF_VAR_maestro_agent_config_file=$(mktemp)
else
    echo "Reading IoT certificate data from RC account state..."
    use_rc_account
    source scripts/read-iot-state.sh "$RESOLVED_REGIONAL_ACCOUNT_ID" "$CLUSTER_ID" "${TF_VAR_region}"
fi

# =====================================================================
# Phase 2: Apply/Destroy MC infrastructure
# =====================================================================
use_mc_account

# Configure Terraform backend (state in MC target account)
export TF_STATE_BUCKET="terraform-state-${TARGET_ACCOUNT_ID}"
export TF_STATE_KEY="management-cluster/${TF_VAR_management_id}.tfstate"
export TF_STATE_REGION="${TARGET_REGION}"

echo "Terraform backend:"
echo "  Bucket: $TF_STATE_BUCKET (target account: $TARGET_ACCOUNT_ID)"
echo "  Key: $TF_STATE_KEY"
echo "  Region: $TF_STATE_REGION"
echo ""

# TF_VAR_maestro_agent_cert_file and TF_VAR_maestro_agent_config_file
# are already exported by read-iot-state.sh

# Runtime TF vars from CodeBuild (not in deploy config)
export TF_VAR_repository_url="${REPOSITORY_URL}"
export TF_VAR_repository_branch="${REPOSITORY_BRANCH:-main}"

# Set container image for ECS tasks (bastion and bootstrap)
if [ -z "${PLATFORM_IMAGE:-}" ]; then
    echo "ERROR: PLATFORM_IMAGE is not set or empty; cannot set TF_VAR_container_image" >&2
    exit 1
fi
export TF_VAR_container_image="${PLATFORM_IMAGE}"

echo "Terraform variables (from deploy config + runtime):"
echo "  Region: $TF_VAR_region"
echo "  Target Account: $TARGET_ACCOUNT_ID"
echo "  Management ID: $TF_VAR_management_id"
echo "  Regional AWS Account: $TF_VAR_regional_aws_account_id"
echo "  Enable Bastion: $TF_VAR_enable_bastion"
echo "  App Code: $TF_VAR_app_code"
echo "  Service Phase: $TF_VAR_service_phase"
echo "  Cost Center: $TF_VAR_cost_center"
echo "  Repository URL: $TF_VAR_repository_url"
echo "  Repository Branch: $TF_VAR_repository_branch"
echo ""

export REGION_DEPLOYMENT="${TF_VAR_region}"
export ENVIRONMENT="${ENVIRONMENT:-staging}"

set +e
if [ "${DELETE_FLAG}" == "true" ]; then
    echo "Destroying management cluster"
    make pipeline-destroy-management
else
    make pipeline-provision-management
fi
MAKE_TARGET_STATUS=$?
set -e

if [ $MAKE_TARGET_STATUS -ne 0 ]; then
    echo "Infrastructure action failed with exit code $MAKE_TARGET_STATUS"
    exit $MAKE_TARGET_STATUS
fi

# Clean up temp cert files
rm -f "${TF_VAR_maestro_agent_cert_file:-}" "${TF_VAR_maestro_agent_config_file:-}"

if [ "${DELETE_FLAG}" == "true" ]; then
     echo "Management cluster destroyed successfully."
else
     echo "Management cluster provisioned successfully."
fi
