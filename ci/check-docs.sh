#!/bin/bash
# CI entrypoint for documentation formatting check.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

npx --no-install prettier --check '**/*.md'
