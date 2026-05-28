#!/usr/bin/env bash
#
# imports.sh - Idempotent Terraform imports for Regional Cluster
#
# Adopts AWS-auto-created CloudWatch log groups into Terraform state so that
# aws_cloudwatch_log_group resources can manage retention + KMS going forward.
#
# Safe to run on any environment:
#   - Fresh env: imports are skipped (resources don't exist yet), TF creates them
#   - Existing env: imports succeed, TF updates retention/KMS in-place
#   - Subsequent runs: all resources already in state, all skipped (~10ms each)
#
# Required env vars: TF_VAR_regional_id
#
# Once all environments have been migrated, this file can be removed.
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../../scripts/pipeline-common/terraform-import.sh"

echo ""
echo "--- Importing existing CloudWatch log groups (Regional Cluster) ---"

# =============================================================================
# Static imports — IDs are deterministic from environment variables
# =============================================================================

import_if_needed \
    'module.maestro_infrastructure.aws_cloudwatch_log_group.rds_postgresql' \
    "/aws/rds/instance/${TF_VAR_regional_id}-maestro/postgresql"

import_if_needed \
    'module.maestro_infrastructure.aws_cloudwatch_log_group.rds_upgrade' \
    "/aws/rds/instance/${TF_VAR_regional_id}-maestro/upgrade"

import_if_needed \
    'module.maestro_infrastructure.aws_cloudwatch_log_group.iot_core' \
    "AWSIotLogsV2"

import_if_needed \
    'module.hyperfleet_infrastructure.aws_cloudwatch_log_group.rds_postgresql' \
    "/aws/rds/instance/${TF_VAR_regional_id}-hyperfleet/postgresql"

import_if_needed \
    'module.hyperfleet_infrastructure.aws_cloudwatch_log_group.rds_upgrade' \
    "/aws/rds/instance/${TF_VAR_regional_id}-hyperfleet/upgrade"

# =============================================================================
# Dynamic imports — IDs depend on resources already in state
# =============================================================================

BROKER_ID=$(tf_state_value \
    'module.hyperfleet_infrastructure.aws_mq_broker.hyperfleet' '.values.id')
echo "  [debug] BROKER_ID=${BROKER_ID:-<empty>}"
if [ -n "$BROKER_ID" ]; then
    import_if_needed \
        'module.hyperfleet_infrastructure.aws_cloudwatch_log_group.mq_general' \
        "/aws/amazonmq/broker/${BROKER_ID}/general"
    import_if_needed \
        'module.hyperfleet_infrastructure.aws_cloudwatch_log_group.mq_connection' \
        "/aws/amazonmq/broker/${BROKER_ID}/connection"
else
    echo "  [skip] AmazonMQ log groups — broker not yet provisioned"
fi

API_ID=$(tf_state_value \
    'module.api_gateway.aws_api_gateway_rest_api.main' '.values.id')
STAGE_NAME=$(tf_state_value \
    'module.api_gateway.aws_api_gateway_stage.main' '.values.stage_name')
STAGE_NAME="${STAGE_NAME:-prod}"
echo "  [debug] API_ID=${API_ID:-<empty>} STAGE_NAME=${STAGE_NAME}"
if [ -n "$API_ID" ]; then
    import_if_needed \
        'module.api_gateway.aws_cloudwatch_log_group.api_gateway_execution' \
        "API-Gateway-Execution-Logs_${API_ID}/${STAGE_NAME}"
else
    echo "  [skip] API GW execution log group — API not yet provisioned"
fi

tf_import_summary
