#!/usr/bin/env bash
# Bootstrap ArgoCD on a Management Cluster.
# Called from: terraform/config/pipeline-management-cluster/buildspec-bootstrap-argocd.yml
set -euo pipefail

echo "=========================================="
echo "ArgoCD Bootstrap for Management Cluster"
echo "Build #${CODEBUILD_BUILD_NUMBER:-?} | ${CODEBUILD_BUILD_ID:-unknown}"
echo "=========================================="

# Pre-flight setup (validates env vars, inits account helpers)
source scripts/pipeline-common/setup-apply-preflight.sh

# Read delete flag from config (GitOps-driven deletion)
ENVIRONMENT="${ENVIRONMENT:-staging}"
MC_CONFIG_FILE="deploy/${ENVIRONMENT}/${TARGET_REGION}/pipeline-management-cluster-${MANAGEMENT_ID}-inputs/terraform.json"
if [ ! -f "$MC_CONFIG_FILE" ]; then
    echo "ERROR: Config file not found: $MC_CONFIG_FILE" >&2
    echo "  ENVIRONMENT=$ENVIRONMENT TARGET_REGION=$TARGET_REGION MANAGEMENT_ID=$MANAGEMENT_ID" >&2
    exit 1
fi
DELETE_FLAG=$(jq -r '.delete // false' "$MC_CONFIG_FILE")

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
    echo "delete=true in config — skipping ArgoCD bootstrap (cluster is being destroyed)"
    exit 0
fi

# Load deploy config to get REGIONAL_AWS_ACCOUNT_ID
source scripts/pipeline-common/load-deploy-config.sh management

RESOLVED_REGIONAL_ACCOUNT_ID="${REGIONAL_AWS_ACCOUNT_ID}"

# =====================================================================
# Read RHOBS API URL from RC terraform state.
# The RC pipeline runs in parallel; wait for the output to be available.
# =====================================================================
echo "Reading RHOBS API URL from RC terraform state..."
_RC_STATE_BUCKET="terraform-state-${RESOLVED_REGIONAL_ACCOUNT_ID}-${TARGET_REGION}"
_RC_REGIONAL_ID=$(jq -r '.regional_id // "regional"' "deploy/${ENVIRONMENT}/${TARGET_REGION}/pipeline-regional-cluster-inputs/terraform.json" 2>/dev/null || echo "regional")
_RC_STATE_KEY="regional-cluster/${_RC_REGIONAL_ID}.tfstate"
_RC_TF_DIR="terraform/config/regional-cluster"

use_rc_account
(cd "$_RC_TF_DIR" && terraform init -reconfigure \
    -backend-config="bucket=${_RC_STATE_BUCKET}" \
    -backend-config="key=${_RC_STATE_KEY}" \
    -backend-config="region=${TARGET_REGION}" \
    -backend-config="use_lockfile=true" >/dev/null 2>&1)

_RC_TIMEOUT=1800
_RC_START=$(date +%s)
export RHOBS_API_URL=""
while [ -z "$RHOBS_API_URL" ]; do
    RHOBS_API_URL=$(cd "$_RC_TF_DIR" && terraform output -raw rhobs_api_url 2>/dev/null || echo "")
    if [ -n "$RHOBS_API_URL" ]; then
        break
    fi
    _ELAPSED=$(( $(date +%s) - _RC_START ))
    if [ "$_ELAPSED" -ge "$_RC_TIMEOUT" ]; then
        echo "ERROR: rhobs_api_url not available after $((_ELAPSED / 60))m. RC pipeline may have failed." >&2
        exit 1
    fi
    echo "  Waiting for RC terraform to publish rhobs_api_url (${_ELAPSED}s elapsed)..."
    sleep 30
done
echo "  RHOBS API URL: ${RHOBS_API_URL}"
echo ""

# =====================================================================
# Bootstrap ArgoCD on Management Cluster
# =====================================================================
use_mc_account
echo ""

echo "Bootstrapping ArgoCD: ${MANAGEMENT_ID} (${TARGET_ACCOUNT_ID}) in ${TARGET_REGION}"
echo ""

# Initialize Terraform backend and verify outputs
./scripts/pipeline-common/init-terraform-backend.sh management-cluster "${TARGET_REGION}" "${MANAGEMENT_ID}"

# Bootstrap ArgoCD (already in target account, no cross-account assume needed)
./scripts/pipeline-common/bootstrap-argocd-wrapper.sh management-cluster "${TARGET_ACCOUNT_ID}"

echo "ArgoCD bootstrap complete."
echo "Management cluster is now fully provisioned and ready for use."
