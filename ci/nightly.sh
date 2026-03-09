#!/bin/bash
# CI entrypoint for nightly tests.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

export AWS_REGION="${AWS_REGION:-us-east-1}"

if [[ "${1:-}" == "--teardown" ]]; then
    uv run --no-cache ci/pre-merge.py --teardown
else
    uv run --no-cache ci/pre-merge.py

    # Discover the API Gateway URL and write it to SHARED_DIR so the
    # test step can pick it up.
    if [[ -n "${SHARED_DIR:-}" ]]; then
        API_ID=$(aws apigateway get-rest-apis --region "$AWS_REGION" \
            --query "items[?starts_with(name, 'regional-cluster-')].id | [0]" --output text)
        echo "https://${API_ID}.execute-api.${AWS_REGION}.amazonaws.com/prod" > "${SHARED_DIR}/api-url"
        echo "API Gateway URL written to ${SHARED_DIR}/api-url"
    fi
fi
