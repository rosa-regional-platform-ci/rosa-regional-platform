#!/usr/bin/env bash
# Mint or destroy IoT certificate in the RC account.
# Called from: terraform/config/pipeline-management-cluster/buildspec-iot-mint.yml
set -euo pipefail

echo "=========================================="
echo "Minting IoT Certificate in RC Account"
echo "Build #${CODEBUILD_BUILD_NUMBER:-?} | ${CODEBUILD_BUILD_ID:-unknown}"
echo "=========================================="

# Initialize account helpers and switch to RC account
source scripts/pipeline-common/account-helpers.sh
init_account_helpers

# Load terraform variables from deploy/ JSON
source scripts/pipeline-common/load-deploy-config.sh management

echo "Cluster ID: ${CLUSTER_ID}"
echo "Regional Account: ${REGIONAL_AWS_ACCOUNT_ID}"
echo ""

# Switch to RC account for IoT operations and state storage
use_rc_account

RC_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
if [ "$TARGET_REGION" = "us-east-1" ]; then
    IOT_STATE_BUCKET="terraform-state-${RC_ACCOUNT_ID}"
else
    IOT_STATE_BUCKET="terraform-state-${RC_ACCOUNT_ID}-${TARGET_REGION}"
fi
IOT_STATE_KEY="maestro-agent-iot/${CLUSTER_ID}.tfstate"

echo "IoT Terraform state:"
echo "  Bucket: $IOT_STATE_BUCKET (RC account: $RC_ACCOUNT_ID)"
echo "  Key: $IOT_STATE_KEY"
echo "  Region: $TARGET_REGION"
echo ""

# Read delete flag from config (GitOps-driven deletion)
ENVIRONMENT="${ENVIRONMENT}"
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

# Generate temporary tfvars for the IoT provisioning
TEMP_TFVARS=$(mktemp /tmp/maestro-iot-XXXXXX.tfvars)
cat > "$TEMP_TFVARS" <<EOF
management_cluster_id = "${CLUSTER_ID}"
app_code              = "${APP_CODE}"
service_phase         = "${SERVICE_PHASE}"
cost_center           = "${COST_CENTER}"
mqtt_topic_prefix     = "sources/maestro/consumers"
EOF

# Run IoT provisioning with persistent remote state
cd terraform/config/maestro-agent-iot-provisioning

terraform init -reconfigure \
    -backend-config="bucket=${IOT_STATE_BUCKET}" \
    -backend-config="key=${IOT_STATE_KEY}" \
    -backend-config="region=${TARGET_REGION}" \
    -backend-config="use_lockfile=true"

if [ "${DELETE_FLAG}" == "true" ]; then
    echo "Destroying IoT resources"
    terraform destroy -var-file="$TEMP_TFVARS" -auto-approve
    echo "IoT resources destroyed successfully"
else
    terraform plan -var-file="$TEMP_TFVARS" -out=tfplan
    terraform apply tfplan
    rm -f tfplan
    echo ""
    echo "IoT certificate minted with persistent state in RC account"
fi

rm -f "$TEMP_TFVARS"

echo "IoT mint stage complete."
