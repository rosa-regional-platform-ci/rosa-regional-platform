#!/bin/bash
# CI entrypoint for nightly tests with a specific machine type override.
#
# Usage:
#   MACHINE_TYPE_OVERRIDE=m6i-large.yaml ./ci/nightly-machine-type.sh
#   MACHINE_TYPE_OVERRIDE=c6i-xlarge.yaml ./ci/nightly-machine-type.sh --teardown

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

export AWS_REGION="${AWS_REGION:-us-east-1}"
echo "AWS_REGION: ${AWS_REGION}"

# Teardown does not require a machine type override — the environment is
# identified by BUILD_ID/eph-prefix, not by instance types.
if [[ "${1:-}" == "--teardown" ]] || [[ "${1:-}" == "--teardown-fire-and-forget" ]]; then
    echo "Running: uv run --no-cache ci/ephemeral-provider/main.py ${1}"
    uv run --no-cache ci/ephemeral-provider/main.py "${1}"
else
    OVERRIDE_FILE="${MACHINE_TYPE_OVERRIDE:?Must set MACHINE_TYPE_OVERRIDE (e.g. m6i-large.yaml)}"
    OVERRIDE_PATH="$(pwd)/ci/nightly-overrides/machine-types/${OVERRIDE_FILE}"

    if [[ ! -f "${OVERRIDE_PATH}" ]]; then
        echo "ERROR: Override file not found: ${OVERRIDE_PATH}" >&2
        echo "Available overrides:" >&2
        ls ci/nightly-overrides/machine-types/ >&2
        exit 1
    fi

    echo "Machine type override: ${OVERRIDE_FILE}"

    SAVE_STATE_ARGS=()
    if [[ -n "${SHARED_DIR:-}" ]]; then
        SAVE_STATE_ARGS=(--save-regional-state "${SHARED_DIR}/regional-terraform-outputs.json")
    fi
    echo "Running: uv run --no-cache ci/ephemeral-provider/main.py --provision-override-file config/defaults.yaml:${OVERRIDE_PATH} ${SAVE_STATE_ARGS[*]:-}"
    uv run --no-cache ci/ephemeral-provider/main.py \
        --provision-override-file "config/defaults.yaml:${OVERRIDE_PATH}" \
        "${SAVE_STATE_ARGS[@]}"
fi
