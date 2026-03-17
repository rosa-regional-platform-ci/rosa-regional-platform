#!/usr/bin/env bash
#
# load-deploy-config.sh - Load terraform variables from deploy/ JSON files
#
# Reads the nested terraform_vars object from rendered deploy/ JSON files and
# exports each key as TF_VAR_<key>. SSM references (ssm://) are resolved
# automatically. This decouples terraform variable changes from the pipeline
# provisioner — changing a var in config.yaml only requires re-running
# render.py and pushing, without re-provisioning pipelines.
#
# Usage:
#   source scripts/pipeline-common/load-deploy-config.sh regional
#   source scripts/pipeline-common/load-deploy-config.sh management
#
# Required environment variables (set by CodeBuild):
#   ENVIRONMENT    - Target environment (e.g., integration, staging)
#   TARGET_REGION  - AWS region (e.g., us-east-1)
#   REGIONAL_ID    - Regional cluster identifier (for regional mode)
#   MANAGEMENT_ID  - Management cluster identifier (for management mode)
#
# Exports:
#   DEPLOY_CONFIG_FILE        - Path to the JSON config file
#   TF_VAR_*                  - All keys from .terraform_vars
#   For management mode only:
#     CLUSTER_ID              - Alias for TF_VAR_management_id
#     RESOLVED_REGIONAL_ACCOUNT_ID - Alias for TF_VAR_regional_aws_account_id

set -euo pipefail

_DEPLOY_MODE="${1:-}"
if [[ -z "$_DEPLOY_MODE" ]]; then
    echo "ERROR: load-deploy-config.sh requires an argument: 'regional' or 'management'" >&2
    exit 1
fi

ENVIRONMENT="${ENVIRONMENT:-staging}"

if [[ "$_DEPLOY_MODE" == "regional" ]]; then
    DEPLOY_CONFIG_FILE="deploy/${ENVIRONMENT}/${TARGET_REGION}/terraform/regional.json"
elif [[ "$_DEPLOY_MODE" == "management" ]]; then
    DEPLOY_CONFIG_FILE="deploy/${ENVIRONMENT}/${TARGET_REGION}/terraform/management/${MANAGEMENT_ID}.json"
else
    echo "ERROR: load-deploy-config.sh: unknown mode '$_DEPLOY_MODE' (expected 'regional' or 'management')" >&2
    exit 1
fi

if [ ! -f "$DEPLOY_CONFIG_FILE" ]; then
    echo "ERROR: Deploy config not found: $DEPLOY_CONFIG_FILE" >&2
    exit 1
fi

echo "Loading deploy config from: $DEPLOY_CONFIG_FILE"

# Export all keys from .terraform_vars as TF_VAR_<key>
while IFS='=' read -r key value; do
    # Resolve ssm:// references
    if [[ "$value" =~ ^ssm:// ]]; then
        _SSM_PARAM_NAME="${value#ssm://}"
        echo "  Resolving SSM parameter: $_SSM_PARAM_NAME in region ${TARGET_REGION}"
        value=$(aws ssm get-parameter \
            --name "$_SSM_PARAM_NAME" \
            --with-decryption \
            --query 'Parameter.Value' \
            --output text \
            --region "${TARGET_REGION}")
        echo "  Resolved: TF_VAR_$key=$value"
    fi

    # Normalize booleans to "true"/"false"
    if [ "$value" == "1" ]; then
        value="true"
    elif [ "$value" == "0" ]; then
        value="false"
    fi

    export "TF_VAR_${key}=${value}"
done < <(jq -r '.terraform_vars | to_entries[] | select(.value | type == "string" or type == "number" or type == "boolean") | "\(.key)=\(.value)"' "$DEPLOY_CONFIG_FILE")

# Management-mode aliases for non-TF consumers (register.sh, iot-mint.sh)
if [[ "$_DEPLOY_MODE" == "management" ]]; then
    CLUSTER_ID="${TF_VAR_management_id}"
    export CLUSTER_ID

    RESOLVED_REGIONAL_ACCOUNT_ID="${TF_VAR_regional_aws_account_id}"
    export RESOLVED_REGIONAL_ACCOUNT_ID

    if [[ -z "${TF_VAR_regional_aws_account_id:-}" ]]; then
        echo "ERROR: regional_aws_account_id must be provided in $DEPLOY_CONFIG_FILE .terraform_vars" >&2
        exit 1
    fi
fi

export DEPLOY_CONFIG_FILE

echo "  Exported TF_VAR_* variables from $DEPLOY_CONFIG_FILE"
[[ "$_DEPLOY_MODE" == "management" ]] && echo "  CLUSTER_ID=$CLUSTER_ID RESOLVED_REGIONAL_ACCOUNT_ID=$RESOLVED_REGIONAL_ACCOUNT_ID"
echo ""
