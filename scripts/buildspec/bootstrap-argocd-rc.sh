#!/usr/bin/env bash
# Bootstrap ArgoCD on a Regional Cluster.
# Called from: terraform/config/pipeline-regional-cluster/buildspec-bootstrap-argocd.yml
set -euo pipefail

echo "=========================================="
echo "ArgoCD Bootstrap for Regional Cluster"
echo "Build #${CODEBUILD_BUILD_NUMBER:-?} | ${CODEBUILD_BUILD_ID:-unknown}"
echo "=========================================="

# Pre-flight setup (validates env vars, inits account helpers)
source scripts/pipeline-common/setup-apply-preflight.sh

# Read delete flag from config (GitOps-driven deletion)
ENVIRONMENT="${ENVIRONMENT:-staging}"
RC_CONFIG_FILE="deploy/${ENVIRONMENT}/${TARGET_REGION}/terraform/regional.json"
if [ ! -f "$RC_CONFIG_FILE" ]; then
    echo "ERROR: Config file not found: $RC_CONFIG_FILE" >&2
    echo "  ENVIRONMENT=$ENVIRONMENT TARGET_REGION=$TARGET_REGION TARGET_ALIAS=$TARGET_ALIAS" >&2
    exit 1
fi
DELETE_FLAG=$(jq -r '.delete // false' "$RC_CONFIG_FILE")

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

# Assume target account role for state and resource operations
use_mc_account
echo ""

echo "Bootstrapping ArgoCD: ${TARGET_ALIAS} (${TARGET_ACCOUNT_ID}) in ${TARGET_REGION}"
echo ""

# Initialize Terraform backend and verify outputs
./scripts/pipeline-common/init-terraform-backend.sh regional-cluster "${TARGET_REGION}" "${TARGET_ALIAS}"

# Bootstrap ArgoCD (already in target account, no cross-account assume needed)
./scripts/pipeline-common/bootstrap-argocd-wrapper.sh regional-cluster "${TARGET_ACCOUNT_ID}"

echo "ArgoCD bootstrap complete. Regional cluster is now fully provisioned and ready for use."
