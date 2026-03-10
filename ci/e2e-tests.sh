#!/bin/bash
# Run e2e API tests from rosa-regional-platform-api against the provisioned environment.
# Expects SHARED_DIR/api-url to exist (written by nightly.sh during provisioning).

set -euo pipefail

# API_URL_FILE="${SHARED_DIR}/api-url"
# if [[ ! -r "${API_URL_FILE}" ]]; then
#   echo "ERROR: ${API_URL_FILE} does not exist or is not readable" >&2
#   exit 1
# fi
# BASE_URL="$(cat "${API_URL_FILE}")"
# export BASE_URL
# echo "Running API e2e tests against ${BASE_URL}"

# API_REF="${API_REF:-main}"
# WORK_DIR="$(mktemp -d)"
# trap 'rm -rf "${WORK_DIR}"' EXIT
# git clone --depth 1 --branch "${API_REF}" \
#   https://github.com/openshift-online/rosa-regional-platform-api.git "${WORK_DIR}/api"
# cd "${WORK_DIR}/api"

# go install github.com/onsi/ginkgo/v2/ginkgo@v2.28.1
# export PATH="$(go env GOPATH)/bin:${PATH}"

# make test-e2e

cd "$(dirname "${BASH_SOURCE[0]}")/.."

export AWS_REGION="${AWS_REGION:-us-east-1}"

uv run ci/e2e-tests.py --shared-dir "${SHARED_DIR}" --region "${AWS_REGION}"
