#!/bin/bash
# Run e2e API tests from rosa-regional-platform-api against the provisioned environment.
# Expects SHARED_DIR/regional-terraform-outputs.json to exist (written by pre-merge.py --save-state).

set -euo pipefail

TF_OUTPUTS="${SHARED_DIR}/regional-terraform-outputs.json"
if [[ ! -r "${TF_OUTPUTS}" ]]; then
  echo "ERROR: ${TF_OUTPUTS} does not exist or is not readable" >&2
  exit 1
fi
BASE_URL="$(jq -r '.api_gateway_invoke_url.value' "${TF_OUTPUTS}")"
export BASE_URL
echo "Running API e2e tests against ${BASE_URL}"

API_REF="${API_REF:-main}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
git clone --depth 1 --branch "${API_REF}" \
  https://github.com/openshift-online/rosa-regional-platform-api.git "${WORK_DIR}/api"
cd "${WORK_DIR}/api"

go install github.com/onsi/ginkgo/v2/ginkgo@v2.28.1
export PATH="$(go env GOPATH)/bin:${PATH}"

make test-e2e
