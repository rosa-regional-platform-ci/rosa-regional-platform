#!/bin/bash
# CI entrypoint for running load tests against an already-provisioned environment.
# Designed to run as a separate Prow step after e2e tests and before teardown.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

export AWS_REGION="${AWS_REGION:-us-east-1}"
echo "AWS_REGION: ${AWS_REGION}"

echo "Running load tests..."
./ci/load-test/run-load-test.sh
