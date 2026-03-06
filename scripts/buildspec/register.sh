#!/usr/bin/env bash
# Register a Management Cluster with the Regional Cluster API.
# Called from: terraform/config/pipeline-management-cluster/buildspec-register.yml
set -euo pipefail

echo "=========================================="
echo "Register MC with Regional Cluster API"
echo "Build #${CODEBUILD_BUILD_NUMBER:-?} | ${CODEBUILD_BUILD_ID:-unknown}"
echo "=========================================="

# Pre-flight setup (validates env vars, inits account helpers)
source scripts/pipeline-common/setup-apply-preflight.sh

# Read delete flag from config (GitOps-driven deletion)
ENVIRONMENT="${ENVIRONMENT:-staging}"
MC_CONFIG_FILE="deploy/${ENVIRONMENT}/${TARGET_REGION}/terraform/management/${TARGET_ALIAS}.json"
if [ ! -f "$MC_CONFIG_FILE" ]; then
    echo "ERROR: Config file not found: $MC_CONFIG_FILE" >&2
    echo "  ENVIRONMENT=$ENVIRONMENT TARGET_REGION=$TARGET_REGION TARGET_ALIAS=$TARGET_ALIAS" >&2
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
    echo "delete=true in config — skipping MC registration (cluster is being destroyed)"
    exit 0
fi

# =====================================================================
# Read API Gateway URL from RC terraform state
# =====================================================================

# Resolve REGIONAL_AWS_ACCOUNT_ID (supports SSM parameter references)
RESOLVED_REGIONAL_ACCOUNT_ID="${REGIONAL_AWS_ACCOUNT_ID}"
if [[ "$RESOLVED_REGIONAL_ACCOUNT_ID" =~ ^ssm:// ]]; then
    SSM_PARAM_NAME="${RESOLVED_REGIONAL_ACCOUNT_ID#ssm://}"
    echo "Resolving SSM parameter: $SSM_PARAM_NAME in region ${TARGET_REGION}"
    RESOLVED_REGIONAL_ACCOUNT_ID=$(aws ssm get-parameter \
        --name "$SSM_PARAM_NAME" \
        --with-decryption \
        --query 'Parameter.Value' \
        --output text \
        --region "${TARGET_REGION}")
    echo "Resolved regional account ID: $RESOLVED_REGIONAL_ACCOUNT_ID"
fi

if [[ -z "$RESOLVED_REGIONAL_ACCOUNT_ID" ]]; then
    echo "ERROR: REGIONAL_AWS_ACCOUNT_ID must be provided"
    exit 1
fi

# Resolve RC state key from regional config (RC alias != MC alias)
RC_CONFIG_FILE="deploy/${ENVIRONMENT}/${TARGET_REGION}/terraform/regional.json"
if [ ! -f "$RC_CONFIG_FILE" ]; then
    echo "ERROR: Regional cluster config not found: $RC_CONFIG_FILE"
    exit 1
fi
RC_ALIAS=$(jq -r '.alias // .region_alias' "$RC_CONFIG_FILE")
echo "Resolved RC alias from config: $RC_ALIAS"

# Assume RC account to read terraform outputs and call API
use_rc_account

RC_STATE_BUCKET="terraform-state-${RESOLVED_REGIONAL_ACCOUNT_ID}"
RC_STATE_KEY="regional-cluster/${RC_ALIAS}.tfstate"

echo "RC state:"
echo "  Bucket: $RC_STATE_BUCKET"
echo "  Key: $RC_STATE_KEY"
echo "  Region: $TARGET_REGION"
echo ""

# Init RC terraform config to read API Gateway URL
(
    cd terraform/config/regional-cluster
    terraform init -reconfigure \
        -backend-config="bucket=${RC_STATE_BUCKET}" \
        -backend-config="key=${RC_STATE_KEY}" \
        -backend-config="region=${TARGET_REGION}" \
        -backend-config="use_lockfile=true"
)

# Retry loop: wait for RC terraform outputs to be available (race condition)
# RC may still be applying when this job starts
MAX_RETRIES=10
RETRY_DELAY=30
RETRY_COUNT=0
API_GATEWAY_URL=""

echo "Waiting for Regional Cluster terraform outputs to be available..."
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    RETRY_COUNT=$((RETRY_COUNT + 1))

    # Refresh terraform state to ensure we have the latest outputs
    # Suppress output unless this is the last attempt
    if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
        (cd terraform/config/regional-cluster && terraform refresh -auto-approve)
    else
        (cd terraform/config/regional-cluster && terraform refresh -auto-approve >/dev/null 2>&1)
    fi

    # Try to get the API Gateway URL - suppress stderr during retries
    if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
        OUTPUT=$(cd terraform/config/regional-cluster && terraform output -raw api_gateway_invoke_url 2>&1)
    else
        OUTPUT=$(cd terraform/config/regional-cluster && terraform output -raw api_gateway_invoke_url 2>/dev/null)
    fi

    # Validate output is a proper URL (starts with https://)
    # This is more reliable than checking for warning text patterns
    if [[ "$OUTPUT" =~ ^https://[a-zA-Z0-9.-]+\.execute-api\. ]]; then
        API_GATEWAY_URL="$OUTPUT"
        echo "✓ Successfully retrieved API Gateway URL after attempt $RETRY_COUNT/$MAX_RETRIES"
        break
    fi

    # Failed to get valid output
    if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
        echo "Attempt $RETRY_COUNT/$MAX_RETRIES: RC outputs not ready yet (got: ${OUTPUT:0:50}...)"
        echo "Waiting ${RETRY_DELAY}s before retry..."
        sleep $RETRY_DELAY
    else
        echo "Attempt $RETRY_COUNT/$MAX_RETRIES: Still no valid output"
        echo "Last output received: $OUTPUT"
    fi
done

if [ -z "$API_GATEWAY_URL" ]; then
    echo ""
    echo "ERROR: Failed to read api_gateway_invoke_url from RC terraform state after $MAX_RETRIES attempts"
    echo "  This likely means:"
    echo "    - Regional Cluster terraform apply failed or is stuck"
    echo "    - Regional Cluster was never fully provisioned"
    echo "    - API Gateway module is not enabled in the Regional Cluster config"
    echo ""
    echo "  Check the Regional Cluster terraform state and apply logs"
    exit 1
fi

echo "API Gateway URL: $API_GATEWAY_URL"
echo ""

# =====================================================================
# Register Management Cluster as consumer
# =====================================================================
echo "Registering management cluster '${CLUSTER_ID}' with Regional Cluster API..."

REGISTER_URL="${API_GATEWAY_URL}/api/v0/management_clusters"
PAYLOAD=$(cat <<EOJSON
{
  "name": "${CLUSTER_ID}",
  "labels": {
    "cluster_type": "management",
    "management_id": "${CLUSTER_ID}",
    "region": "${TARGET_REGION}",
    "alias": "${TARGET_ALIAS}"
  }
}
EOJSON
)

echo "POST $REGISTER_URL"
echo "Payload: $PAYLOAD"
echo ""

# Use curl with AWS SigV4 signing (built into curl, no extra deps)
# Session token header is required when using assumed-role (temporary)
# credentials but must be omitted for static IAM user credentials.
SECURITY_TOKEN_HEADER=()
if [ -n "${AWS_SESSION_TOKEN:-}" ]; then
    SECURITY_TOKEN_HEADER=(-H "x-amz-security-token: ${AWS_SESSION_TOKEN}")
fi

HTTP_CODE=$(curl -s -o /tmp/register-response.json -w "%{http_code}" \
    --aws-sigv4 "aws:amz:${TARGET_REGION}:execute-api" \
    --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
    "${SECURITY_TOKEN_HEADER[@]}" \
    -X POST "$REGISTER_URL" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD")

RESPONSE=$(cat /tmp/register-response.json)
echo "HTTP Status: $HTTP_CODE"
echo "Response: $RESPONSE"
echo ""

# 201 = created, 409/502 = already exists (both are fine)
if [ "$HTTP_CODE" = "201" ]; then
    echo "Management cluster '${CLUSTER_ID}' registered successfully."
elif [ "$HTTP_CODE" = "409" ] || [ "$HTTP_CODE" = "502" ]; then
    echo "Management cluster '${CLUSTER_ID}' is already registered (HTTP $HTTP_CODE). Skipping."
    if [ "$HTTP_CODE" = "502" ]; then
        echo "WARNING: Maestro returned 502 for 'already exists' — this should be a 409 Conflict."
        echo "  This indicates a bug in Maestro or the API Gateway configuration."
    fi
else
    echo "ERROR: Registration failed with HTTP $HTTP_CODE"
    echo "Response: $RESPONSE"
    exit 1
fi
echo "Management cluster registration complete."
