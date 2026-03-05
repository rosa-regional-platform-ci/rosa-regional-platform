#!/bin/bash
# CI entrypoint for nightly tests.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ "${1:-}" == "--teardown" ]]; then
    uv run --no-cache ci/pre-merge.py --teardown
else
    uv run --no-cache ci/pre-merge.py
fi

# TODO: Run tests against integration
