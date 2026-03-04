#!/bin/bash
set -euo pipefail

## ===============================
## Helper Functions
## ===============================

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }
log_info() { log " $1"; }
log_success() { log " $1"; }
log_error() { log " $1" >&2; }
log_phase() {
    echo ""
    echo "=========================================="
    log "$1"
    echo "=========================================="
}

## ===============================
## Parse Arguments
## ===============================

TEARDOWN=false
BOOTSTRAP_CENTRAL=false
for arg in "$@"; do
  case "$arg" in
    --teardown) TEARDOWN=true ;;
    --bootstrap-central-account) BOOTSTRAP_CENTRAL=true ;;
    *)
      log_error "Unknown argument: $arg"
      echo "Usage: $0 [--teardown] [--bootstrap-central-account]" >&2
      exit 1
      ;;
  esac
done

## ===============================
## Configuration
## ===============================

export AWS_REGION="${AWS_REGION:-us-east-1}"
export GITHUB_REPOSITORY=$(echo "${REPOSITORY_URL:-openshift-online/rosa-regional-platform}" | sed -E 's|.*github.com/||; s|\.git$||')
export GITHUB_BRANCH="${REPOSITORY_BRANCH:-main}"
export TARGET_ENVIRONMENT="${TARGET_ENV:-e2e}"

log_phase "Configuration:"
log_info "  Region:      ${AWS_REGION}"
log_info "  Repo:        ${GITHUB_REPOSITORY}"
log_info "  Branch:      ${GITHUB_BRANCH}"
log_info "  Environment: ${TARGET_ENVIRONMENT}"

## ===============================
## Credential Setup
## ===============================

log_phase "Setting up central account access"
# Load central account credentials

# Credentials mounted at /var/run/rosa-credentials/ via ci-operator credentials mount
CREDS_DIR="/var/run/rosa-credentials/"

# 1. Setup Central Account (Primary Identity)
export AWS_ACCESS_KEY_ID=$(< "${CREDS_DIR}/ci_access_key")
export AWS_SECRET_ACCESS_KEY=$(< "${CREDS_DIR}/ci_secret_key")

# Perform Assume Role for Central CI Role
ASSUME_ROLE_ARN=$(< "${CREDS_DIR}/ci_assume_role_arn")
ROLE_JSON=$(aws sts assume-role \
    --role-arn "${ASSUME_ROLE_ARN}" \
    --role-session-name "e2e-test-$(date +%s)")

export AWS_ACCESS_KEY_ID=$(echo "${ROLE_JSON}" | jq -r .Credentials.AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(echo "${ROLE_JSON}" | jq -r .Credentials.SecretAccessKey)
export AWS_SESSION_TOKEN=$(echo "${ROLE_JSON}" | jq -r .Credentials.SessionToken)

CENTRAL_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
log_info "Access set up to Central CI Account ID: ${CENTRAL_ACCOUNT_ID}"

# ==============================================================================
# TEMPORARY: Function to setup trust policy in sub-accounts
# TODO(typeid): We should have least priviledge role (not OrganizationAccessRole) 
# by default in the minted RC/MC accounts.
# ==============================================================================
setup_target_account_pipeline_trust() {
    local prefix=$1
    log_info "Temporary Setup: Updating trust policy in ${prefix} account"

    local role_name="OrganizationAccountAccessRole"
    local principal="arn:aws:iam::${CENTRAL_ACCOUNT_ID}:root"

    # Subshell: environment changes stay inside the ( )
    (
        unset AWS_SESSION_TOKEN
        export AWS_ACCESS_KEY_ID=$(< "${CREDS_DIR}/${prefix}_access_key")
        export AWS_SECRET_ACCESS_KEY=$(< "${CREDS_DIR}/${prefix}_secret_key")

        # Fetch existing trust policy
        local existing_policy
        existing_policy=$(aws iam get-role \
            --role-name "${role_name}" \
            --query 'Role.AssumeRolePolicyDocument' --output json)

        # Check if the principal is already trusted
        if echo "${existing_policy}" | jq -e \
            --arg principal "${principal}" \
            '.Statement[] | select(.Effect == "Allow" and .Action == "sts:AssumeRole" and .Principal.AWS == $principal)' \
            > /dev/null 2>&1; then
            log_info "Trust for ${principal} already exists in ${prefix} account, skipping."
            exit 0
        fi

        # Append the new statement to the existing policy
        local updated_policy
        updated_policy=$(echo "${existing_policy}" | jq \
            --arg principal "${principal}" \
            '.Statement += [{
                "Effect": "Allow",
                "Principal": { "AWS": $principal },
                "Action": "sts:AssumeRole"
            }]')

        aws iam update-assume-role-policy \
            --role-name "${role_name}" \
            --policy-document "${updated_policy}"
    )

    log_success "Updated trust on ${role_name} in ${prefix} account to allow assumeRole from ${principal}."
}

# Run the temporary setup for both target accounts
log_phase "Setting up trust policies for pipeline role in regional and management account"
setup_target_account_pipeline_trust "regional"
setup_target_account_pipeline_trust "management"

## ===============================
## Pipeline Helper Functions
## ===============================

# Wait for a CodePipeline execution to complete.
# Usage: wait_for_pipeline <pipeline-name> <execution-id>
wait_for_pipeline() {
    POLL_INTERVAL=30
    local pipeline_name=$1
    local execution_id=$2

    log_info "Watching pipeline '${pipeline_name}' execution '${execution_id}'..."

    while true; do
        local status
        status=$(aws codepipeline get-pipeline-execution \
            --pipeline-name "${pipeline_name}" \
            --pipeline-execution-id "${execution_id}" \
            --query 'pipelineExecution.status' --output text 2>&1) || {
            # V2 QUEUED pipelines have a propagation delay — execution may not
            # be visible immediately after start-pipeline-execution returns.
            log_info "Pipeline '${pipeline_name}' not yet visible — waiting ${POLL_INTERVAL}s..."
            sleep "${POLL_INTERVAL}"
            continue
        }

        case "${status}" in
            Succeeded)
                log_success "Pipeline '${pipeline_name}' succeeded."
                return 0
                ;;
            Failed|Stopped|Cancelled)
                log_error "Pipeline '${pipeline_name}' finished with status: ${status}"
                return 1
                ;;
            InProgress|Stopping)
                log_info "Pipeline '${pipeline_name}' status: ${status} — waiting ${POLL_INTERVAL}s..."
                sleep "${POLL_INTERVAL}"
                ;;
            *)
                log_error "Pipeline '${pipeline_name}' unexpected status: ${status}"
                return 1
                ;;
        esac
    done
}

# Discover pipelines matching a prefix that were started after a given timestamp.
# Returns "pipeline-name:execution-id" lines for each match.
# Usage: discover_pipelines <prefix> <after-timestamp>
# TODO: Replace timestamp-based discovery with a unique identifier (e.g. source commit SHA
# or a tag on the pipeline execution) to avoid potential collisions with parallel e2e runs.
discover_pipelines() {
    local prefix=$1
    local after_ts=$2

    aws codepipeline list-pipelines --query "pipelines[?starts_with(name, '${prefix}')].name" --output text | tr '\t' '\n' | grep "^${prefix}" | while read -r name; do
        local exec_id
        exec_id=$(aws codepipeline list-pipeline-executions \
            --pipeline-name "${name}" --max-items 1 \
            --query "pipelineExecutionSummaries[?lastUpdateTime>=\`${after_ts}\`].pipelineExecutionId | [0]" \
            --output text)
        if [ -n "${exec_id}" ] && [ "${exec_id}" != "None" ]; then
            echo "${name}:${exec_id}"
        fi
    done
}

# Start a pipeline with a variable override and return the execution ID.
# Usage: start_pipeline_with_variable <pipeline-name> <var-name> <var-value>
start_pipeline_with_variable() {
    local pipeline_name=$1
    local var_name=$2
    local var_value=$3

    aws codepipeline start-pipeline-execution \
        --name "${pipeline_name}" \
        --variables "name=${var_name},value=${var_value}" \
        --query 'pipelineExecutionId' --output text
}

## ===============================
## Teardown Mode
## ===============================

# TODO(typeid): Teardown orchestration should migrate into the provisioner itself so that
# it handles the full sequence (destroy MC infra, destroy RC infra, destroy pipeline resources).

if [ "${TEARDOWN}" = true ]; then
  log_phase "Teardown: Destroying MC Infrastructure"

  # 1. Discover MC pipelines and start each with IS_DESTROY=true
  MC_PIPELINES=$(aws codepipeline list-pipelines \
      --query "pipelines[?starts_with(name, 'mc-pipe-')].name" --output text | tr '\t' '\n' | grep '^mc-pipe-' || true)

  MC_FAILED=0
  for mc_name in ${MC_PIPELINES}; do
      log_info "Starting ${mc_name} with IS_DESTROY=true..."
      mc_exec_id=$(start_pipeline_with_variable "${mc_name}" "IS_DESTROY" "true")
      wait_for_pipeline "${mc_name}" "${mc_exec_id}" || MC_FAILED=$((MC_FAILED + 1))
  done

  if [ "${MC_FAILED}" -gt 0 ]; then
      log_error "${MC_FAILED} MC pipeline(s) failed during teardown."
      exit 1
  fi

  # 2. Discover RC pipelines and start each with IS_DESTROY=true
  log_phase "Teardown: Destroying RC Infrastructure"

  RC_PIPELINES=$(aws codepipeline list-pipelines \
      --query "pipelines[?starts_with(name, 'rc-pipe-')].name" --output text | tr '\t' '\n' | grep '^rc-pipe-' || true)

  RC_FAILED=0
  for rc_name in ${RC_PIPELINES}; do
      log_info "Starting ${rc_name} with IS_DESTROY=true..."
      rc_exec_id=$(start_pipeline_with_variable "${rc_name}" "IS_DESTROY" "true")
      wait_for_pipeline "${rc_name}" "${rc_exec_id}" || RC_FAILED=$((RC_FAILED + 1))
  done

  if [ "${RC_FAILED}" -gt 0 ]; then
      log_error "${RC_FAILED} RC pipeline(s) failed during teardown."
      exit 1
  fi

  # 3. Start provisioner with FORCE_DELETE_ALL_PIPELINES=true to remove pipeline resources
  log_phase "Teardown: Destroying Pipeline Resources"

  PROVISIONER_EXEC_ID=$(start_pipeline_with_variable "pipeline-provisioner" "FORCE_DELETE_ALL_PIPELINES" "true")
  wait_for_pipeline "pipeline-provisioner" "${PROVISIONER_EXEC_ID}"

  log_success "Teardown complete."
  exit 0
fi

## ===============================
## Provisioning
## ===============================

if [ "${BOOTSTRAP_CENTRAL}" = true ]; then
    log_phase "Bootstrapping Central Account"
    ./scripts/bootstrap-central-account.sh
fi

# Record timestamp before starting so we can discover pipelines created after this point
PROVISION_START=$(date -u +%Y-%m-%dT%H:%M:%S)

log_phase "Starting Pipeline Provisioner"
PROVISIONER_EXEC_ID=$(aws codepipeline start-pipeline-execution \
    --name pipeline-provisioner \
    --query 'pipelineExecutionId' --output text)
wait_for_pipeline "pipeline-provisioner" "${PROVISIONER_EXEC_ID}"

log_phase "Watching RC/MC Pipelines"

ALL_PIPELINES=$(
    discover_pipelines "rc-pipe-" "${PROVISION_START}"
    discover_pipelines "mc-pipe-" "${PROVISION_START}"
)

if [ -z "${ALL_PIPELINES}" ]; then
    log_error "No RC/MC pipelines found after provisioner completed."
    exit 1
fi

FAILED=0
while IFS=: read -r name exec_id; do
    [ -z "${name}" ] && continue
    wait_for_pipeline "${name}" "${exec_id}" || FAILED=$((FAILED + 1))
done <<< "${ALL_PIPELINES}"

if [ "${FAILED}" -gt 0 ]; then
    log_error "${FAILED} pipeline(s) failed."
    exit 1
fi

## ===============================
## Validation
## ===============================

log_phase "Running Validation"
unset AWS_SESSION_TOKEN
export AWS_ACCESS_KEY_ID=$(< "${CREDS_DIR}/regional_access_key")
export AWS_SECRET_ACCESS_KEY=$(< "${CREDS_DIR}/regional_secret_key")
# TODO(typeid): we need to get the right API url and MC ID here.
# ./ci/e2e-platform-api-test.sh