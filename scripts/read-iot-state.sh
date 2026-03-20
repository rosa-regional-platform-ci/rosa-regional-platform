#!/bin/bash
# =============================================================================
# Read IoT State Outputs from Regional Cluster Account
# =============================================================================
# This script reads Maestro IoT certificate and config outputs from the
# regional cluster's terraform state and exports file paths for use by
# the management cluster terraform.
#
# MUST be sourced (not executed) so exports propagate to the caller.
#
# Prerequisites:
#   - AWS credentials must already be configured for the RC account
#   - Terraform installed
#   - IoT resources previously provisioned via provision-maestro-agent-iot-regional.sh
#
# Usage:
#   source scripts/read-iot-state.sh <RC_ACCOUNT_ID> <CLUSTER_ID> <REGION>
#
# Exports:
#   TF_VAR_maestro_agent_cert_file   - path to temp file with agent cert JSON
#   TF_VAR_maestro_agent_config_file - path to temp file with agent config JSON
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "ERROR: This script must be sourced, not executed." >&2
    echo "Usage: source $0 <RC_ACCOUNT_ID> <CLUSTER_ID> <REGION>" >&2
    exit 1
fi

if [[ $# -ne 3 ]]; then
    echo "ERROR: read-iot-state.sh requires 3 arguments: <RC_ACCOUNT_ID> <CLUSTER_ID> <REGION>" >&2
    return 1
fi

_READ_IOT_RC_ACCOUNT_ID="$1"
_READ_IOT_CLUSTER_ID="$2"
_READ_IOT_REGION="$3"

_READ_IOT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_READ_IOT_REPO_ROOT="$(cd "$_READ_IOT_SCRIPT_DIR/.." && pwd)"
_READ_IOT_TF_DIR="$_READ_IOT_REPO_ROOT/terraform/config/maestro-agent-iot-provisioning"

if [ "$_READ_IOT_REGION" = "us-east-1" ]; then
    _READ_IOT_STATE_BUCKET="terraform-state-${_READ_IOT_RC_ACCOUNT_ID}"
else
    _READ_IOT_STATE_BUCKET="terraform-state-${_READ_IOT_RC_ACCOUNT_ID}-${_READ_IOT_REGION}"
fi
_READ_IOT_STATE_KEY="maestro-agent-iot/${_READ_IOT_CLUSTER_ID}.tfstate"

echo "Reading IoT state from RC account..."
echo "  Bucket: $_READ_IOT_STATE_BUCKET"
echo "  Key:    $_READ_IOT_STATE_KEY"
echo "  Region: $_READ_IOT_REGION"
echo ""

# Init IoT terraform config to read outputs from RC state
(
    cd "$_READ_IOT_TF_DIR"
    terraform init -reconfigure \
        -backend-config="bucket=${_READ_IOT_STATE_BUCKET}" \
        -backend-config="key=${_READ_IOT_STATE_KEY}" \
        -backend-config="region=${_READ_IOT_REGION}" \
        -backend-config="use_lockfile=true"
)

# Extract cert and config to temporary files (avoids passing large
# JSON blobs through environment variables / shell quoting)
TF_VAR_maestro_agent_cert_file=$(mktemp /tmp/agent-cert-XXXXXX.json)
TF_VAR_maestro_agent_config_file=$(mktemp /tmp/agent-config-XXXXXX.json)

(cd "$_READ_IOT_TF_DIR" && terraform output -json agent_cert) > "$TF_VAR_maestro_agent_cert_file" || true
(cd "$_READ_IOT_TF_DIR" && terraform output -json agent_config) > "$TF_VAR_maestro_agent_config_file" || true

if [ ! -s "$TF_VAR_maestro_agent_cert_file" ] || [ "$(cat "$TF_VAR_maestro_agent_cert_file")" = "null" ]; then
    echo "ERROR: Failed to read agent_cert from IoT terraform state" >&2
    echo "Ensure IoT provisioning has run successfully for cluster: $_READ_IOT_CLUSTER_ID" >&2
    rm -f "$TF_VAR_maestro_agent_cert_file" "$TF_VAR_maestro_agent_config_file"
    unset TF_VAR_maestro_agent_cert_file TF_VAR_maestro_agent_config_file
    return 1
fi

if [ ! -s "$TF_VAR_maestro_agent_config_file" ] || [ "$(cat "$TF_VAR_maestro_agent_config_file")" = "null" ]; then
    echo "ERROR: Failed to read agent_config from IoT terraform state" >&2
    echo "Ensure IoT provisioning has run successfully for cluster: $_READ_IOT_CLUSTER_ID" >&2
    rm -f "$TF_VAR_maestro_agent_cert_file" "$TF_VAR_maestro_agent_config_file"
    unset TF_VAR_maestro_agent_cert_file TF_VAR_maestro_agent_config_file
    return 1
fi

export TF_VAR_maestro_agent_cert_file
export TF_VAR_maestro_agent_config_file

echo "IoT state read successfully"
echo "  Cert file:   $TF_VAR_maestro_agent_cert_file"
echo "  Config file: $TF_VAR_maestro_agent_config_file"
echo ""

# Clean up internal variables
unset _READ_IOT_RC_ACCOUNT_ID _READ_IOT_CLUSTER_ID _READ_IOT_REGION
unset _READ_IOT_SCRIPT_DIR _READ_IOT_REPO_ROOT _READ_IOT_TF_DIR
unset _READ_IOT_STATE_BUCKET _READ_IOT_STATE_KEY
