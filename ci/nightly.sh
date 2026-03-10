#!/bin/bash
# CI entrypoint for nightly tests.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

export AWS_REGION="${AWS_REGION:-us-east-1}"

if [[ "${1:-}" == "--teardown" ]]; then
    uv run --no-cache ci/pre-merge.py --teardown
else
    SAVE_STATE_ARGS=()
    if [[ -n "${SHARED_DIR:-}" ]]; then
        SAVE_STATE_ARGS=(--save-state "${SHARED_DIR}/regional-terraform-outputs.json")
    fi
    uv run --no-cache ci/pre-merge.py "${SAVE_STATE_ARGS[@]}"
fi
