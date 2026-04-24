#!/bin/bash
# CI entrypoint for nightly tests.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

export AWS_REGION="${AWS_REGION:-us-east-1}"
echo "AWS_REGION: ${AWS_REGION}"

# Generate AWS profiles from Prow-mounted credential files.
# All downstream consumers (aws.py, e2e-tests.sh, collect-cluster-logs.sh)
# expect named profiles (rrp-central, rrp-rc, rrp-mc) via AWS_CONFIG_FILE.
source ci/setup-aws-profiles.sh

if [[ "${1:-}" == "--teardown" ]] || [[ "${1:-}" == "--teardown-fire-and-forget" ]]; then
    echo "Running: uv run --no-cache ci/ephemeral-provider/main.py ${1}"
    uv run --no-cache ci/ephemeral-provider/main.py "${1}"
else
    SAVE_STATE_ARGS=()
    if [[ -n "${SHARED_DIR:-}" ]]; then
        SAVE_STATE_ARGS=(--save-regional-state "${SHARED_DIR}/regional-terraform-outputs.json")
    fi
    echo "Running: uv run --no-cache ci/ephemeral-provider/main.py ${SAVE_STATE_ARGS[@]}"
    uv run --no-cache ci/ephemeral-provider/main.py "${SAVE_STATE_ARGS[@]}"
fi
