#!/usr/bin/env bash
# Mint or destroy IoT certificate in the RC account.
# Called from: terraform/config/pipeline-management-cluster/buildspec-iot-mint.yml
set -euo pipefail

source scripts/pipeline-common/lib.sh

preflight_check
config_load management

# Resolve REGIONAL_ID from RC deploy config if not already set
if [ -z "${REGIONAL_ID:-}" ]; then
    RC_CONFIG_FILE="deploy/${ENVIRONMENT}/${TARGET_REGION}/pipeline-regional-cluster-inputs/terraform.json"
    if [ -f "$RC_CONFIG_FILE" ]; then
        REGIONAL_ID=$(jq -r '.regional_id' "$RC_CONFIG_FILE")
    else
        echo "ERROR: Cannot determine REGIONAL_ID — not set and RC config not found: $RC_CONFIG_FILE" >&2
        exit 1
    fi
fi

# Switch to RC account for IoT operations and state storage
use_rc_account

RC_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
IOT_STATE_BUCKET="terraform-state-${RC_ACCOUNT_ID}-${TARGET_REGION}"
IOT_STATE_KEY="maestro-agent-iot/${CLUSTER_ID}.tfstate"

# Read delete flag from config (GitOps-driven deletion)
MC_CONFIG_FILE="deploy/${ENVIRONMENT}/${TARGET_REGION}/pipeline-management-cluster-${MANAGEMENT_ID}-inputs/terraform.json"
if [ ! -f "$MC_CONFIG_FILE" ]; then
    echo "ERROR: Config file not found: $MC_CONFIG_FILE" >&2
    exit 1
fi
DELETE_FLAG=$(jq -r '.delete // false' "$MC_CONFIG_FILE")
[ "${IS_DESTROY:-false}" == "true" ] && DELETE_FLAG="true"

# Generate temporary tfvars for the IoT provisioning
TEMP_TFVARS=$(mktemp /tmp/maestro-iot-XXXXXX.tfvars)
cat > "$TEMP_TFVARS" <<EOF
management_cluster_id = "${CLUSTER_ID}"
app_code              = "${APP_CODE}"
service_phase         = "${SERVICE_PHASE}"
cost_center           = "${COST_CENTER}"
mqtt_topic_prefix     = "sources/${REGIONAL_ID}/consumers"
EOF

# Run IoT provisioning with persistent remote state
cd terraform/config/maestro-agent-iot-provisioning

terraform init -reconfigure \
    -backend-config="bucket=${IOT_STATE_BUCKET}" \
    -backend-config="key=${IOT_STATE_KEY}" \
    -backend-config="region=${TARGET_REGION}" \
    -backend-config="use_lockfile=true"

if [ "${DELETE_FLAG}" == "true" ]; then
    terraform destroy -var-file="$TEMP_TFVARS" -auto-approve
else
    terraform plan -var-file="$TEMP_TFVARS" -out=tfplan
    terraform apply tfplan
    rm -f tfplan
fi

rm -f "$TEMP_TFVARS"
