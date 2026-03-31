#!/bin/bash
# Run e2e API tests from rosa-regional-platform-api against the provisioned environment.
# API URL is read from ${CREDS_DIR}/api_url if available, otherwise from
# SHARED_DIR/regional-terraform-outputs.json (written by ci/ephemeral-provider/main.py --save-state).
#
# AWS credentials are expected via AWS profiles (AWS_CONFIG_FILE must be set).
# In CI, source ci/setup-aws-profiles.sh before running this script.

set -euo pipefail

CREDS_DIR="${CREDS_DIR:-/var/run/rosa-credentials}"

if [[ -n "${BASE_URL:-}" ]]; then
  echo "Using BASE_URL from environment: ${BASE_URL}"
else
  if [[ -r "${CREDS_DIR}/api_url" ]]; then
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
fi
export BASE_URL
echo "Running API e2e tests against ${BASE_URL}"

# Use the regional account profile for authenticated API calls
export AWS_PROFILE="rrp-rc"
export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
E2E_REF="${E2E_REF:-main}"
E2E_REPO="${E2E_REPO:-https://github.com/openshift-online/rosa-regional-platform-api.git}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
git clone --depth 1 --branch "${E2E_REF}" \
  "${E2E_REPO}" "${WORK_DIR}/api"
cd "${WORK_DIR}/api"

go install github.com/onsi/ginkgo/v2/ginkgo@v2.28.1
export PATH="$(go env GOPATH)/bin:${PATH}"

rc=0
make test-e2e || rc=$?

if [[ $rc -ne 0 ]]; then
    echo ""
    echo "E2E tests failed (exit code: $rc). Collecting cluster logs..."

    # Pre-existing environment (integration): bare cluster names (regional, mc01)
    # Ephemeral environment: ci_prefix-based names derived from BUILD_ID
    if [[ -r "${CREDS_DIR}/api_url" ]]; then
        export CLUSTER_PREFIX=""
    elif [[ -n "${BUILD_ID:-}" ]]; then
        hash="$(echo -n "${BUILD_ID}" | sha256sum | cut -c1-6)" \
            || { echo "WARNING: sha256sum failed — skipping log collection"; hash=""; }
        if [[ -n "$hash" ]]; then
            export CLUSTER_PREFIX="ci-${hash}-"
        fi
    else
        echo "WARNING: BUILD_ID not set — skipping log collection"
    fi

    if [[ -n "${CLUSTER_PREFIX+set}" ]]; then
        # Logs are left in S3 rather than added to public CI artifacts because
        # they may contain sensitive data (e.g. maestro secrets) that cannot be
        # reliably redacted. The S3 URIs are printed below for manual retrieval.
        S3_ONLY=true \
            "${REPO_ROOT}/scripts/dev/collect-cluster-logs.sh" || true
    fi
    exit $rc
fi
