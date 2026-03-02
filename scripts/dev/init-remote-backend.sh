#!/bin/bash
#
# init-remote-backend.sh - Initialize Terraform backend against remote S3 state
#
# Reads the deploy/<environment>/<region>/terraform/ configs to compute the
# cluster identifier, then generates a backend_override.tf pointing at the S3 state
# bucket in the target account (where resources reside) and runs terraform init.
#
# For local dev, authenticate directly to the target account (no cross-account
# assume role needed since state is now in the same account as resources).
#
# After this, terraform output (and therefore bastion-connect.sh,
# bastion-port-forward.sh, etc.) will work locally.
#
# Usage:
#   ./scripts/dev/init-remote-backend.sh <cluster-type> <environment> <region> [--mc <name>]
#
# Arguments:
#   cluster-type        - regional or management
#   environment         - Sector/environment name (e.g. psav-central, integration)
#   region-deployment   - Region deployment
#
# Options:
#   --mc <name>      Management cluster name (for management type, default: auto-detect)
#
# Examples:
#   ./scripts/dev/init-remote-backend.sh regional psav-central us-east-1
#   ./scripts/dev/init-remote-backend.sh regional integration us-east-1
#   ./scripts/dev/init-remote-backend.sh management psav-central us-east-1
#   ./scripts/dev/init-remote-backend.sh management integration us-east-2 --mc mc01-us-east-2

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEPLOY_DIR="$REPO_ROOT/deploy"

# ── Parse arguments ─────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $0 <cluster-type> <environment> <region> [options]

Initialize Terraform backend against remote S3 state in the central account.

Arguments:
  cluster-type   regional or management
  environment    Sector/environment name (e.g. psav-central, integration)
  region         AWS region

Options:
  --mc <name>    Management cluster name (default: auto-detect single MC)

Available environments:
EOF
    # List available environments from deploy/
    if [ -d "$DEPLOY_DIR" ]; then
        for env_dir in "$DEPLOY_DIR"/*/; do
            [ -d "$env_dir" ] || continue
            env_name=$(basename "$env_dir")
            region_deployments=$(ls -d "$env_dir"*/ 2>/dev/null | xargs -I{} basename {} | tr '\n' ', ' | sed 's/,$//')
            echo "  $env_name  ($region_deployments)"
        done
    fi
    exit 1
}

if [ $# -lt 3 ]; then
    usage
fi

CLUSTER_TYPE="$1"
shift

# Validate cluster type
case "$CLUSTER_TYPE" in
    regional|management) ;;
    *)
        echo "Error: cluster-type must be 'regional' or 'management', got '$CLUSTER_TYPE'"
        echo ""
        usage
        ;;
esac

ENVIRONMENT="$1"
REGION_DEPLOYMENT="$2"
shift 2

# Parse optional flags
MC_NAME=""

while [ $# -gt 0 ]; do
    case "$1" in
        --mc)
            MC_NAME="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Error: Unknown option '$1'"
            usage
            ;;
    esac
done

# ── Resolve environment and region ─────────────────────────────────────────

ENV_DIR="$DEPLOY_DIR/$ENVIRONMENT"
if [ ! -d "$ENV_DIR" ]; then
    echo "Error: Environment '$ENVIRONMENT' not found in deploy/"
    echo ""
    echo "Available environments:"
    ls -d "$DEPLOY_DIR"/*/ 2>/dev/null | xargs -I{} basename {}
    exit 1
fi

REGION_DEPLOYMENT_DIR="$ENV_DIR/$REGION_DEPLOYMENT"
if [ ! -d "$REGION_DEPLOYMENT_DIR" ]; then
    echo "Error: Region '$REGION_DEPLOYMENT' not found in deploy/$ENVIRONMENT/"
    echo ""
    echo "Available regions:"
    ls -d "$ENV_DIR"/*/ 2>/dev/null | xargs -I{} basename {}
    exit 1
fi

# ── Compute cluster ID from deploy config ─────────────────────────────────

CONFIG_DIR="$REPO_ROOT/terraform/config/${CLUSTER_TYPE}-cluster"
STATE_PREFIX="${CLUSTER_TYPE}-cluster"

if [ "$CLUSTER_TYPE" = "regional" ]; then
    CONFIG_FILE="$REGION_DEPLOYMENT_DIR/terraform/regional.json"
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Error: Regional config not found: $CONFIG_FILE"
        exit 1
    fi
    CLUSTER_ID=$(jq -r '.alias // empty' "$CONFIG_FILE")
    if [ -z "$CLUSTER_ID" ]; then
        echo "Error: No 'alias' field in $CONFIG_FILE"
        exit 1
    fi
    echo "==> Resolved cluster ID from regional.json: $CLUSTER_ID"
else
    # Management cluster — find the right MC config
    MC_DIR="$REGION_DEPLOYMENT_DIR/terraform/management"
    if [ ! -d "$MC_DIR" ]; then
        echo "Error: No management cluster configs in $MC_DIR"
        exit 1
    fi

    if [ -n "$MC_NAME" ]; then
        CONFIG_FILE="$MC_DIR/${MC_NAME}.json"
        if [ ! -f "$CONFIG_FILE" ]; then
            echo "Error: Management cluster config not found: $CONFIG_FILE"
            echo ""
            echo "Available management clusters:"
            ls "$MC_DIR"/*.json 2>/dev/null | xargs -I{} basename {} .json | sed 's/^/  /'
            exit 1
        fi
    else
        # Auto-detect single MC
        MC_FILES=("$MC_DIR"/*.json)
        if [ ${#MC_FILES[@]} -eq 1 ]; then
            CONFIG_FILE="${MC_FILES[0]}"
            MC_NAME=$(basename "$CONFIG_FILE" .json)
            echo "==> Auto-detected management cluster: $MC_NAME"
        else
            echo "Error: Multiple management clusters found, use --mc to specify:"
            for f in "${MC_FILES[@]}"; do
                echo "  $(basename "$f" .json)"
            done
            exit 1
        fi
    fi

    CLUSTER_ID=$(jq -r '.alias // empty' "$CONFIG_FILE")
    if [ -z "$CLUSTER_ID" ]; then
        echo "Error: No 'alias' field in $CONFIG_FILE"
        exit 1
    fi
    echo "==> Resolved cluster ID from $(basename "$CONFIG_FILE"): $CLUSTER_ID"
fi

echo "    Environment: $ENVIRONMENT"
echo "    Region:      $REGION"
echo "    Cluster ID:  $CLUSTER_ID"
echo ""

# ── Detect target account and state bucket ─────────────────────────────────
# State is stored in the target account (where resources reside).
# For local dev, authenticate directly to the target account.

echo "==> Detecting target account..."
TARGET_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
TF_STATE_BUCKET="terraform-state-${TARGET_ACCOUNT_ID}"
echo "    Account:  $TARGET_ACCOUNT_ID"
echo "    Bucket:   $TF_STATE_BUCKET"

# Detect bucket region
BUCKET_REGION=$(aws s3api get-bucket-location \
    --bucket "$TF_STATE_BUCKET" \
    --region us-east-1 \
    --query LocationConstraint --output text)

if [ "$BUCKET_REGION" == "None" ] || [ "$BUCKET_REGION" == "null" ] || [ -z "$BUCKET_REGION" ]; then
    BUCKET_REGION="us-east-1"
fi
echo "    Region:   $BUCKET_REGION"
echo ""

# ── Verify config directory ───────────────────────────────────────────────

if [ ! -d "$CONFIG_DIR" ]; then
    echo "Error: Terraform config directory not found: $CONFIG_DIR"
    exit 1
fi

# ── Verify state exists ──────────────────────────────────────────────────

STATE_KEY="${STATE_PREFIX}/${CLUSTER_ID}.tfstate"
if ! aws s3 ls "s3://${TF_STATE_BUCKET}/${STATE_KEY}" > /dev/null 2>&1; then
    echo "Warning: State file not found: s3://${TF_STATE_BUCKET}/${STATE_KEY}"
    echo ""
    echo "Available state files for ${STATE_PREFIX}/:"
    aws s3 ls "s3://${TF_STATE_BUCKET}/${STATE_PREFIX}/" \
        | grep '\.tfstate$' \
        | awk '{print $NF}' \
        | sed 's/\.tfstate$//' \
        | while read -r key; do
            echo "    $key"
        done
    echo ""
    read -rp "Continue anyway? (y/N) " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# ── Generate backend_override.tf ─────────────────────────────────────────

OVERRIDE_FILE="$CONFIG_DIR/backend_override.tf"

cat > "$OVERRIDE_FILE" <<EOF
# Auto-generated by init-remote-backend.sh — do not commit (gitignored via *_override.tf)
terraform {
  backend "s3" {
    bucket       = "${TF_STATE_BUCKET}"
    key          = "${STATE_KEY}"
    region       = "${BUCKET_REGION}"
    use_lockfile = true
  }
}
EOF

echo "==> Generated $OVERRIDE_FILE"
cat "$OVERRIDE_FILE"
echo ""

# ── Terraform init ───────────────────────────────────────────────────────

echo "==> Running terraform init in $CONFIG_DIR..."
(
    cd "$CONFIG_DIR"
    terraform init -reconfigure
)

echo ""
echo "==> Done! Terraform is now configured against remote state."
echo "    Cluster type: $CLUSTER_TYPE"
echo "    Environment:  $ENVIRONMENT"
echo "    Region:       $REGION"
echo "    Cluster ID:   $CLUSTER_ID"
echo "    State:        s3://${TF_STATE_BUCKET}/${STATE_KEY}"
echo ""
