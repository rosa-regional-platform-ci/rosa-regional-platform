#!/usr/bin/env bash
#
# Generate an AWS config file with standardized profiles from CI credentials.
#
# In CI (Prow), credentials are mounted as individual files under CREDS_DIR
# (default: /var/run/rosa-credentials/). This script reads those files and
# writes an AWS config with profiles that match the interface expected by all
# downstream consumers (aws.py, e2e-tests.sh, janitor, collect-cluster-logs).
#
# Profile names:
#   rrp-admin    — static IAM keys (source for central role assumption)
#   rrp-central  — central account via AssumeRole from rrp-admin
#   rrp-rc       — regional account (direct keys)
#   rrp-mc       — management account (direct keys)
#
# After sourcing, AWS_CONFIG_FILE and AWS_SHARED_CREDENTIALS_FILE are exported.
#
# Usage:
#   source ci/setup-aws-profiles.sh
#
# TODO: In the future, CI could mount a pre-built AWS config file directly,
# eliminating the need for this script entirely.

set -euo pipefail

CREDS_DIR="${CREDS_DIR:-/var/run/rosa-credentials}"

_read_cred() {
    local name="$1"
    local env_var
    env_var=$(echo "$name" | tr 'a-z' 'A-Z')
    if [[ -n "${!env_var:-}" ]]; then
        echo "${!env_var}"
    elif [[ -r "${CREDS_DIR}/${name}" ]]; then
        cat "${CREDS_DIR}/${name}"
    else
        echo "Error: credential '${name}' not found in env (${env_var}) or ${CREDS_DIR}/${name}" >&2
        return 1
    fi
}

_aws_config_dir=$(mktemp -d)
export AWS_CONFIG_FILE="${_aws_config_dir}/config"
export AWS_SHARED_CREDENTIALS_FILE="${_aws_config_dir}/credentials"
touch "$AWS_SHARED_CREDENTIALS_FILE"

cat > "$AWS_CONFIG_FILE" <<AWSCFG
[profile rrp-admin]
aws_access_key_id = $(_read_cred central_access_key)
aws_secret_access_key = $(_read_cred central_secret_key)
region = us-east-1

[profile rrp-central]
role_arn = $(_read_cred central_assume_role_arn)
source_profile = rrp-admin
region = us-east-1
duration_seconds = 3600

[profile rrp-rc]
aws_access_key_id = $(_read_cred regional_access_key)
aws_secret_access_key = $(_read_cred regional_secret_key)
region = us-east-1

[profile rrp-mc]
aws_access_key_id = $(_read_cred management_access_key)
aws_secret_access_key = $(_read_cred management_secret_key)
region = us-east-1
AWSCFG

echo "AWS profiles configured (config: ${AWS_CONFIG_FILE})"
