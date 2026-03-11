#!/bin/bash
# Run e2e API tests from rosa-regional-platform-api against the provisioned environment.
# API URL is read from ${CREDS_DIR}/api_url if available, otherwise from
# SHARED_DIR/regional-terraform-outputs.json (written by pre-merge.py --save-state).

set -euo pipefail

CREDS_DIR="${CREDS_DIR:-/var/run/rosa-credentials}"
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
  BASE_URL="$(jq -r '.api_gateway_invoke_url.value' "${TF_OUTPUTS}")"
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

make test-e2e
