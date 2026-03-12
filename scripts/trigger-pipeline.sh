#!/usr/bin/env bash

set -euo pipefail

REGION="us-east-2"
PIPELINE_NAME="${1:-}"

if [ -z "$PIPELINE_NAME" ]; then
    echo "Usage: $0 <pipeline-name>"
    echo ""
    echo "Available pipelines in ${REGION}:"
    echo ""

    # Get list of pipeline names
    PIPELINES=$(aws codepipeline list-pipelines --region "${REGION}" --query 'pipelines[].name' --output text)

    if [ -z "$PIPELINES" ]; then
        echo "No pipelines found in ${REGION}"
        exit 0
    fi

    # Print table header
    printf "%-50s %-20s %-30s\n" "PIPELINE NAME" "STATUS" "LAST UPDATED"
    printf "%s\n" "$(printf '%.0s-' {1..100})"

    # Get details for each pipeline
    for pipeline in $PIPELINES; do
        # Get pipeline execution summary
        EXECUTION=$(aws codepipeline get-pipeline-state \
            --name "$pipeline" \
            --region "${REGION}" \
            --query '{status: stageStates[0].latestExecution.status, updated: stageStates[0].latestExecution.lastStatusChange}' \
            --output json 2>/dev/null || echo '{"status":"N/A","updated":"N/A"}')

        STATUS=$(echo "$EXECUTION" | jq -r '.status // "N/A"')
        UPDATED=$(echo "$EXECUTION" | jq -r '.updated // "N/A"')

        # Format timestamp if it's not N/A
        if [ "$UPDATED" != "N/A" ]; then
            UPDATED=$(date -d "$UPDATED" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$UPDATED")
        fi

        printf "%-50s %-20s %-30s\n" "$pipeline" "$STATUS" "$UPDATED"
    done

    exit 1
fi

echo "Triggering pipeline: ${PIPELINE_NAME} in ${REGION}..."

# Start the pipeline execution
EXECUTION_ID=$(aws codepipeline start-pipeline-execution \
    --name "${PIPELINE_NAME}" \
    --region "${REGION}" \
    --query 'pipelineExecutionId' \
    --output text)

echo "✓ Pipeline execution started successfully"
echo "  Execution ID: ${EXECUTION_ID}"
echo ""
echo "Monitor execution at:"
echo "  https://${REGION}.console.aws.amazon.com/codesuite/codepipeline/pipelines/${PIPELINE_NAME}/executions/${EXECUTION_ID}"
