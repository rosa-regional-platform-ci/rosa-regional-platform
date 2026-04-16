#!/bin/bash
# Run k6 load tests against a provisioned environment.
# Reads API URL from terraform outputs or environment, same pattern as ci/e2e-tests.sh.

set -euo pipefail

CREDS_DIR="${CREDS_DIR:-/var/run/rosa-credentials}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ---------------------------------------------------------------------------
# Discover BASE_URL (same logic as ci/e2e-tests.sh)
# ---------------------------------------------------------------------------
if [[ -n "${BASE_URL:-}" ]]; then
    echo "Using BASE_URL from environment: ${BASE_URL}"
elif [[ -r "${CREDS_DIR}/api_url" ]]; then
    echo "Using API URL from ${CREDS_DIR}/api_url (pre-existing environment)"
    BASE_URL="$(cat "${CREDS_DIR}/api_url")"
else
    echo "No ${CREDS_DIR}/api_url found, falling back to terraform outputs (ephemeral environment)"
    TF_OUTPUTS="${SHARED_DIR}/regional-terraform-outputs.json"
    if [[ ! -r "${TF_OUTPUTS}" ]]; then
        echo "ERROR: ${TF_OUTPUTS} does not exist or is not readable" >&2
        exit 1
    fi
    BASE_URL="$(jq -r '.api_gateway_invoke_url.value // empty' "${TF_OUTPUTS}")"
    if [[ -z "${BASE_URL}" ]]; then
        echo "ERROR: api_gateway_invoke_url.value not found in ${TF_OUTPUTS}" >&2
        exit 1
    fi
fi
export BASE_URL

# ---------------------------------------------------------------------------
# AWS credentials for SigV4 signing
# ---------------------------------------------------------------------------
if [[ -r "${CREDS_DIR}/regional_access_key" ]] && [[ -r "${CREDS_DIR}/regional_secret_key" ]]; then
    export AWS_ACCESS_KEY_ID="$(cat "${CREDS_DIR}/regional_access_key")"
    export AWS_SECRET_ACCESS_KEY="$(cat "${CREDS_DIR}/regional_secret_key")"
    export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"
    echo "AWS credentials loaded from ${CREDS_DIR}"
else
    echo "ERROR: AWS credentials not found or not readable at ${CREDS_DIR}/regional_access_key and ${CREDS_DIR}/regional_secret_key" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Enable mutating operations (MC create/delete, ManifestWork post) in CI.
# Unset this when running against standing environments to avoid resource leaks.
# ---------------------------------------------------------------------------
export LOAD_TEST_MUTATE="${LOAD_TEST_MUTATE:-true}"

# ---------------------------------------------------------------------------
# Output directory for results
# ---------------------------------------------------------------------------
RESULTS_DIR="${ARTIFACT_DIR:-/tmp}/load-test-results"
mkdir -p "${RESULTS_DIR}"

# ---------------------------------------------------------------------------
# Run load tests
# ---------------------------------------------------------------------------
echo ""
echo "=========================================="
echo "Running Platform API Load Test"
echo "=========================================="
echo "  BASE_URL: ${BASE_URL}"
echo "  Results:  ${RESULTS_DIR}/"
echo ""

k6 run \
    --summary-export "${RESULTS_DIR}/platform-api-summary.json" \
    --out json="${RESULTS_DIR}/platform-api-results.json" \
    "${SCRIPT_DIR}/scripts/platform-api-load.js"

echo ""
echo "=========================================="
echo "Running HCP Lifecycle Load Test"
echo "=========================================="
echo ""

k6 run \
    --summary-export "${RESULTS_DIR}/hcp-lifecycle-summary.json" \
    --out json="${RESULTS_DIR}/hcp-lifecycle-results.json" \
    "${SCRIPT_DIR}/scripts/hcp-lifecycle-load.js"

echo ""
echo "=========================================="
echo "Load tests complete"
echo "=========================================="
echo "Results saved to: ${RESULTS_DIR}/"
ls -la "${RESULTS_DIR}/"

# ---------------------------------------------------------------------------
# Baseline comparison
# ---------------------------------------------------------------------------
if [[ -x "${SCRIPT_DIR}/compare-baseline.py" ]]; then
    echo ""
    echo "Running baseline comparison..."
    python3 "${SCRIPT_DIR}/compare-baseline.py" \
        --results "${RESULTS_DIR}/platform-api-summary.json" \
        --bucket "${LOAD_TEST_BASELINE_BUCKET:-rosa-ci-artifacts}" \
        --key "load-test-baselines/latest.json" \
        --threshold "${REGRESSION_THRESHOLD_PCT:-20}"
fi
