#!/usr/bin/env bash

set -euo pipefail

REGION="us-east-2"
PIPELINE_NAME="${1:-}"

if [ -z "$PIPELINE_NAME" ]; then
    echo "Usage: $0 <pipeline-name>"
    echo ""
    echo "Tails CloudWatch logs for the latest CodeBuild execution in the pipeline"
    exit 1
fi

echo "Fetching latest execution for pipeline: ${PIPELINE_NAME}..."

# Get the latest pipeline execution
EXECUTION_ID=$(aws codepipeline list-pipeline-executions \
    --pipeline-name "${PIPELINE_NAME}" \
    --region "${REGION}" \
    --max-items 1 \
    --query 'pipelineExecutionSummaries[0].pipelineExecutionId' \
    --output text)

if [ -z "$EXECUTION_ID" ] || [ "$EXECUTION_ID" = "None" ]; then
    echo "No executions found for pipeline: ${PIPELINE_NAME}"
    exit 1
fi

echo "Latest execution ID: ${EXECUTION_ID}"
echo ""

# Extract CodeBuild project names from the pipeline definition
PIPELINE_DEF=$(aws codepipeline get-pipeline \
    --name "${PIPELINE_NAME}" \
    --region "${REGION}")

# Find all CodeBuild actions in the pipeline
CODEBUILD_PROJECTS=$(echo "$PIPELINE_DEF" | jq -r '.pipeline.stages[].actions[] | select(.actionTypeId.provider == "CodeBuild") | .configuration.ProjectName' | sort -u)

if [ -z "$CODEBUILD_PROJECTS" ]; then
    echo "No CodeBuild actions found in pipeline: ${PIPELINE_NAME}"
    exit 1
fi

# Count how many CodeBuild projects we found
PROJECT_COUNT=$(echo "$CODEBUILD_PROJECTS" | wc -l | tr -d ' ')

if [ "$PROJECT_COUNT" -eq 1 ]; then
    # Single CodeBuild project - tail directly
    PROJECT_NAME=$(echo "$CODEBUILD_PROJECTS" | head -1)
    echo "Tailing logs for CodeBuild project: ${PROJECT_NAME}"
    echo "Press Ctrl+C to stop"
    echo ""

    aws logs tail "/aws/codebuild/${PROJECT_NAME}" \
        --follow \
        --region "${REGION}" \
        --format short
else
    # Multiple CodeBuild projects - let user choose
    echo "Multiple CodeBuild projects found in pipeline:"
    echo ""

    i=1
    while IFS= read -r project; do
        echo "  ${i}. ${project}"
        i=$((i + 1))
    done <<< "$CODEBUILD_PROJECTS"

    echo ""
    echo -n "Select project number (1-${PROJECT_COUNT}): "
    read -r selection

    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt "$PROJECT_COUNT" ]; then
        echo "Invalid selection"
        exit 1
    fi

    PROJECT_NAME=$(echo "$CODEBUILD_PROJECTS" | sed -n "${selection}p")
    echo ""
    echo "Tailing logs for CodeBuild project: ${PROJECT_NAME}"
    echo "Press Ctrl+C to stop"
    echo ""

    aws logs tail "/aws/codebuild/${PROJECT_NAME}" \
        --follow \
        --region "${REGION}" \
        --format short
fi
