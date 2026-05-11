#!/bin/bash
# Run e2e API tests from rosa-regional-platform-api against the provisioned environment.
# API URL is read from ${CREDS_DIR}/api_url if available, otherwise from
# SHARED_DIR/regional-terraform-outputs.json (written by ci/ephemeral-provider/main.py --save-state).

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

# Set up AWS credentials for authenticated API calls (e.g. aws sts get-caller-identity)
if [[ -r "${CREDS_DIR}/regional_access_key" ]]; then
  export AWS_ACCESS_KEY_ID="$(cat "${CREDS_DIR}/regional_access_key")"
  export AWS_SECRET_ACCESS_KEY="$(cat "${CREDS_DIR}/regional_secret_key")"
  export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"
  echo "AWS credentials loaded from ${CREDS_DIR}"
else
  echo "WARNING: No credentials found at ${CREDS_DIR}/regional_access_key"
fi

API_REF="${API_REF:-main}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
git clone --depth 1 --branch "${API_REF}" \
  https://github.com/openshift-online/rosa-regional-platform-api.git "${WORK_DIR}/api"
cd "${WORK_DIR}/api"

go install github.com/onsi/ginkgo/v2/ginkgo@v2.28.1
export PATH="$(go env GOPATH)/bin:${PATH}"

# Poll the platform API liveness endpoint before running tests.  The API
# Gateway backend may not be ready immediately after provision completes
# (e.g. platform-api pod still starting or VPC Link not yet healthy).
# Mirrors the retry loop in ci/e2e-platform-api-test.sh.
echo "Waiting for platform API to become ready at ${BASE_URL}/v0/live..."
_ready=false
for _attempt in $(seq 1 20); do
    _resp=$(curl -sf \
        --aws-sigv4 "aws:amz:${AWS_DEFAULT_REGION:-us-east-1}:execute-api" \
        --user "${AWS_ACCESS_KEY_ID:-}:${AWS_SECRET_ACCESS_KEY:-}" \
        "${BASE_URL}/v0/live" 2>/dev/null) || _resp=""
    if [[ "${_resp}" == *"ok"* ]]; then
        echo "Platform API is ready."
        _ready=true
        break
    fi
    echo "Attempt ${_attempt}/20: API not ready (response: ${_resp:-<no response>}), retrying in 30s..."
    [[ "${_attempt}" -lt 20 ]] && sleep 30
done
unset _attempt _resp
if [[ "${_ready}" != "true" ]]; then
    echo "ERROR: Platform API at ${BASE_URL}/v0/live did not become healthy within 10 minutes." >&2
    exit 1
fi
unset _ready

make test-e2e
