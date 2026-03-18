#!/bin/bash
# Quick validation for ArgoCD rendered config before provisioning
set -euo pipefail

CLUSTER_TYPE="${1:-}"

# Set defaults from environment variables
ENVIRONMENT="${ENVIRONMENT:-integration}"
REGION_DEPLOYMENT="${REGION_DEPLOYMENT:-}"

if [[ -z "$CLUSTER_TYPE" || -z "$REGION_DEPLOYMENT" ]]; then
    echo "Usage: ENVIRONMENT=<env> REGION_DEPLOYMENT=<region-alias> $0 <cluster-type>"
    echo ""
    echo "Arguments:"
    echo "  cluster-type: management-cluster or regional-cluster"
    echo ""
    echo "Required environment variables:"
    echo "  REGION_DEPLOYMENT: The region alias from config.yaml (e.g., us-east-1, us-east-1-fedramp)"
    echo ""
    echo "Optional environment variables:"
    echo "  ENVIRONMENT (default: integration)"
    exit 1
fi

REQUIRED_FILES=(
    "deploy/${ENVIRONMENT}/${REGION_DEPLOYMENT}/argocd-values-${CLUSTER_TYPE}.yaml"
    "deploy/${ENVIRONMENT}/${REGION_DEPLOYMENT}/argocd-bootstrap-${CLUSTER_TYPE}/applicationset.yaml"
)

missing_files=()
for file in "${REQUIRED_FILES[@]}"; do
    if [[ ! -f "$file" ]]; then
        missing_files+=("$file")
    fi
done

if [[ ${#missing_files[@]} -gt 0 ]]; then
    echo "ERROR: Missing rendered ArgoCD config for ${ENVIRONMENT}/${REGION_DEPLOYMENT}"
    echo ""
    echo "Missing: ${missing_files[*]}"
    echo ""
    echo "Fix: 1) Add ${ENVIRONMENT}/${REGION_DEPLOYMENT} to config.yaml"
    echo "     2) Run ./scripts/render.py"
    echo "     3) Commit and push to your target branch"
    exit 1
fi

echo "ArgoCD config exists for ${ENVIRONMENT}/${REGION_DEPLOYMENT}"
