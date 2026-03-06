#!/bin/bash
# Download CloudWatch logs for all CodeBuild projects matching a CI prefix.
# Usage: ./ci/download-codebuild-logs.sh <ci-prefix> [region]
# Example: ./ci/download-codebuild-logs.sh ci-202982

set -euo pipefail

CI_PREFIX="${1:?Usage: $0 <ci-prefix> [region]}"
REGION="${2:-us-east-1}"
OUT_DIR="codebuild-logs-${CI_PREFIX}"

mkdir -p "$OUT_DIR"

# Portable in-place sed: macOS requires -i '', GNU sed requires -i
sed_inplace() {
  if sed --version 2>/dev/null | grep -q GNU; then
    sed -i "$@"
  else
    sed -i '' "$@"
  fi
}

echo "Searching for log groups matching /aws/codebuild/${CI_PREFIX}-* in ${REGION}..."

LOG_GROUPS=$(aws logs describe-log-groups \
  --log-group-name-prefix "/aws/codebuild/${CI_PREFIX}-" \
  --region "$REGION" \
  --query 'logGroups[].logGroupName' \
  --output text)

if [[ -z "$LOG_GROUPS" ]]; then
  echo "No log groups found."
  exit 0
fi

for LOG_GROUP in $LOG_GROUPS; do
  PROJECT_NAME="${LOG_GROUP##*/}"
  echo "Downloading ${LOG_GROUP}..."

  STREAMS=$(aws logs describe-log-streams \
    --log-group-name "$LOG_GROUP" \
    --region "$REGION" \
    --order-by LastEventTime \
    --descending \
    --query 'logStreams[].logStreamName' \
    --output text)

  if [[ -z "$STREAMS" || "$STREAMS" == "None" ]]; then
    echo "  (no log streams)"
    continue
  fi

  # Streams are ordered most-recent-first (descending). Convert to an array
  # and iterate in reverse so index 0 = oldest, giving chronological filenames.
  read -ra STREAM_ARRAY <<< "$STREAMS"
  TOTAL=${#STREAM_ARRAY[@]}

  for (( i = TOTAL - 1; i >= 0; i-- )); do
    STREAM="${STREAM_ARRAY[$i]}"
    IDX=$(( TOTAL - 1 - i ))
    SAFE_NAME="${PROJECT_NAME}.${IDX}.log"

    echo "  stream ${IDX}: ${STREAM} -> ${OUT_DIR}/${SAFE_NAME}"

    aws logs get-log-events \
      --log-group-name "$LOG_GROUP" \
      --log-stream-name "$STREAM" \
      --region "$REGION" \
      --start-from-head \
      --query 'events[].message' \
      --output text > "${OUT_DIR}/${SAFE_NAME}"

    # Strip ANSI color codes
    sed_inplace 's/\x1b\[[0-9;]*m//g' "${OUT_DIR}/${SAFE_NAME}"

    LINES=$(wc -l < "${OUT_DIR}/${SAFE_NAME}")
    echo "    ${LINES} lines"
  done
done

echo ""
echo "Logs saved to ${OUT_DIR}/"
ls -la "${OUT_DIR}/"
