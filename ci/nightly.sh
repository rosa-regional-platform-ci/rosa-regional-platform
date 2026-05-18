#!/bin/bash
# CI entrypoint for nightly tests.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

export AWS_REGION="${AWS_REGION:-us-east-1}"
echo "AWS_REGION: ${AWS_REGION}"

# Load AWS profiles from Prow-mounted aws_config file.
source ci/setup-aws-profiles.sh

# Build provision override args from PROVISION_OVERRIDE_FILES env var.
# Format: "target1:override1,target2:override2"
# Example: PROVISION_OVERRIDE_FILES="config/ephemeral/defaults.yaml:ci/overrides/on-demand-e2e-ou-path.yaml"
OVERRIDE_ARGS=()
if [[ -n "${PROVISION_OVERRIDE_FILES:-}" ]]; then
    IFS=',' read -ra _OVERRIDES <<< "${PROVISION_OVERRIDE_FILES}"
    for _ENTRY in "${_OVERRIDES[@]}"; do
        OVERRIDE_ARGS+=(--provision-override-file "${_ENTRY}")
    done
fi

if [[ "${1:-}" == "--teardown" ]] || [[ "${1:-}" == "--teardown-fire-and-forget" ]]; then
    echo "Running: uv run --no-cache ci/ephemeral-provider/main.py ${1}"
    uv run --no-cache ci/ephemeral-provider/main.py "${1}"
else
    SAVE_STATE_ARGS=()
    if [[ -n "${SHARED_DIR:-}" ]]; then
        SAVE_STATE_ARGS=(--save-regional-state "${SHARED_DIR}/regional-terraform-outputs.json")
    fi
    echo "Running: uv run --no-cache ci/ephemeral-provider/main.py ${OVERRIDE_ARGS[*]:-} ${SAVE_STATE_ARGS[*]:-}"
    uv run --no-cache ci/ephemeral-provider/main.py "${OVERRIDE_ARGS[@]}" "${SAVE_STATE_ARGS[@]}"
fi
