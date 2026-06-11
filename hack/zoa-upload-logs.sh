#!/bin/bash
# Watches for upload jobs in zoa-jobs namespace and prints their logs.
# Run on MC bastion while testing ZOA executions.
# Usage: bash zoa-upload-logs.sh

NS="zoa-jobs"
SEEN=""

echo "Watching for upload jobs in ${NS}..."

while true; do
  POD=$(kubectl get pods -n "$NS" -l job-name -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -- '-upload')

  if [ -n "$POD" ] && [[ "$SEEN" != *"$POD"* ]]; then
    echo "--- Found upload pod: $POD ---"
    kubectl wait --for=condition=Ready "pod/$POD" -n "$NS" --timeout=30s 2>/dev/null
    kubectl logs -n "$NS" "$POD" --follow 2>/dev/null
    echo "--- End $POD ---"
    echo ""
    SEEN="${SEEN} ${POD}"
  fi

  sleep 2
done
