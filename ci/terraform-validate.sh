#!/bin/bash
# CI entrypoint for Terraform validation.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
make terraform-validate
