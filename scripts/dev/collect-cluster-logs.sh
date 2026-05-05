#!/bin/bash
# Collect RC and MC kubernetes logs via the log-collector ECS task.
#
# This script is the single implementation for log collection, used by both
# the local dev CLI (ephemeral-env.sh) and CI (ci/e2e-tests.sh).
#
# Callers set CLUSTER_PREFIX to control cluster name resolution:
#   - Ephemeral: CLUSTER_PREFIX="eph-a1b2c3-" → eph-a1b2c3-regional, eph-a1b2c3-mc01
#   - Integration: CLUSTER_PREFIX="" → regional, mc01
#
# MC clusters are discovered dynamically by listing ECS clusters matching
# ${CLUSTER_PREFIX}mc*-bastion, so mc01, mc02, etc. are all collected.
#
# Usage:
#   collect-cluster-logs.sh [regional|management|all]
#
# Required environment variables:
#   CLUSTER_PREFIX  — Cluster name prefix (e.g. "eph-a1b2c3-" or "" for bare names)
#
# Credentials (one of the following):
#   REGIONAL_AK / REGIONAL_SK   — Direct credential env vars (dev workflow)
#   MANAGEMENT_AK / MANAGEMENT_SK
#     -- or --
#   CREDS_DIR                   — Directory with credential files (CI workflow)
#                                 (regional_access_key, management_access_key, etc.)
#
# Optional:
#   LOG_OUTPUT_DIR  — Output directory (default: /tmp/<prefix>logs-<timestamp>)
#   S3_ONLY         — If set to "true", skip downloading logs and leave them in S3.
#                     Prints the S3 URI so callers can fetch logs manually.
#                     Used in CI to avoid publishing sensitive data (e.g. maestro
#                     secrets) to public artifact stores.
#
# All collection failures are logged but do not cause a non-zero exit, so
# this script is safe to call from test failure handlers.

set -uo pipefail

CREDS_DIR="${CREDS_DIR:-/var/run/rosa-credentials}"

RC_NAMESPACES="ns/argocd ns/maestro-server ns/platform-api ns/hyperfleet-system ns/monitoring"
MC_NAMESPACES="ns/argocd ns/hypershift ns/maestro-agent ns/monitoring ns/cert-manager"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Portable sed in-place: macOS needs `sed -i ''`, Linux needs `sed -i`
sed_inplace() {
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

redact_logs() {
    local dir="$1"
    find "$dir" -type f \( -name "*.yaml" -o -name "*.log" -o -name "*.txt" -o -name "*.json" \) | while read -r f; do
        [[ -s "$f" ]] || continue
        sed_inplace \
            -e 's/\(AKIA\|ASIA\)[A-Z0-9]\{16\}/[REDACTED_AWS_KEY]/g' \
            -e 's/\(aws_secret_access_key\|secret_key\)\([ =:]*\)[^ ]*/\1\2[REDACTED]/gi' \
            -e 's/\(aws_session_token\|security_token\)\([ =:]*\)[^ ]*/\1\2[REDACTED]/gi' \
            -e 's/"\(aws_secret_access_key\|secret_key\)"[[:space:]]*:[[:space:]]*"[^"]*"/"\1":"[REDACTED]"/gi' \
            -e 's/"\(aws_session_token\|security_token\)"[[:space:]]*:[[:space:]]*"[^"]*"/"\1":"[REDACTED]"/gi' \
            "$f"
    done
}

# Set AWS credentials for a given account type ("regional" or "management").
# Prefers direct env vars (REGIONAL_AK/SK), falls back to CREDS_DIR files.
setup_aws_creds() {
    local account_type="$1"

    if [[ "$account_type" == "regional" ]]; then
        if [[ -n "${REGIONAL_AK:-}" && -n "${REGIONAL_SK:-}" ]]; then
            export AWS_ACCESS_KEY_ID="$REGIONAL_AK"
            export AWS_SECRET_ACCESS_KEY="$REGIONAL_SK"
        elif [[ -r "${CREDS_DIR}/regional_access_key" && -r "${CREDS_DIR}/regional_secret_key" ]]; then
            export AWS_ACCESS_KEY_ID="$(cat "${CREDS_DIR}/regional_access_key")"
            export AWS_SECRET_ACCESS_KEY="$(cat "${CREDS_DIR}/regional_secret_key")"
        else
            echo "  No credentials available for regional account"
            return 1
        fi
    else
        if [[ -n "${MANAGEMENT_AK:-}" && -n "${MANAGEMENT_SK:-}" ]]; then
            export AWS_ACCESS_KEY_ID="$MANAGEMENT_AK"
            export AWS_SECRET_ACCESS_KEY="$MANAGEMENT_SK"
        elif [[ -r "${CREDS_DIR}/management_access_key" && -r "${CREDS_DIR}/management_secret_key" ]]; then
            export AWS_ACCESS_KEY_ID="$(cat "${CREDS_DIR}/management_access_key")"
            export AWS_SECRET_ACCESS_KEY="$(cat "${CREDS_DIR}/management_secret_key")"
        else
            echo "  No credentials available for management account"
            return 1
        fi
    fi
}

# Ensure the log-collection S3 bucket exists (account-regional namespace).
# Creates the bucket on first use; subsequent calls are no-ops.
ensure_logs_bucket() {
    local account_id="$1"
    local region="$2"
    local bucket="bastion-log-collection-${account_id}-${region}-an"

    if aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
        return 0
    fi

    echo "  Creating log-collection bucket ${bucket}..."
    aws s3api create-bucket \
        --bucket "$bucket" \
        --bucket-namespace account-regional \
        --region "$region" > /dev/null

    aws s3api put-public-access-block \
        --bucket "$bucket" \
        --public-access-block-configuration \
            BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true > /dev/null

    aws s3api put-bucket-lifecycle-configuration \
        --bucket "$bucket" \
        --lifecycle-configuration '{"Rules":[{"ID":"expire-logs","Status":"Enabled","Filter":{"Prefix":""},"Expiration":{"Days":7},"AbortIncompleteMultipartUpload":{"DaysAfterInitiation":1}}]}' > /dev/null
}

# Discover MC cluster IDs by listing ECS clusters matching ${prefix}mc*-bastion.
# Outputs one cluster_id per line (e.g. "eph-a1b2c3-mc01", "mc01").
discover_mc_clusters() {
    local prefix="$1"
    aws ecs list-clusters --query 'clusterArns[*]' --output text 2>/dev/null \
        | tr '\t' '\n' \
        | grep -oE "[^/]+$" \
        | grep "^${prefix}mc.*-bastion$" \
        | sed 's/-bastion$//' \
        | sort
}

# ---------------------------------------------------------------------------
# Core: collect logs for one cluster
# ---------------------------------------------------------------------------

collect_logs_for_cluster() {
    local cluster_id="$1"
    local namespaces="$2"
    local out_dir="$3"

    echo "==> Collecting logs from ${cluster_id}..."

    local ecs_cluster="${cluster_id}-bastion"
    local task_def="${cluster_id}-log-collector"
    local account_id region
    account_id=$(aws sts get-caller-identity --query Account --output text) \
        || { echo "  Could not determine account ID"; return 1; }
    region="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || echo "us-east-1")}}"
    local s3_bucket="bastion-log-collection-${account_id}-${region}-an"

    ensure_logs_bucket "$account_id" "$region"
    local s3_key="collect-logs-$(date +%s%N)-$$-${RANDOM}.tar.gz"

    # Discover network config from the bastion security group
    local sg_id subnets vpc_id
    sg_id=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=${cluster_id}-bastion" \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null) \
        || { echo "  Could not find security group for ${cluster_id}"; return 1; }
    [[ "$sg_id" != "None" && -n "$sg_id" ]] \
        || { echo "  Security group '${cluster_id}-bastion' not found"; return 1; }

    vpc_id=$(aws ec2 describe-security-groups \
        --group-ids "$sg_id" \
        --query 'SecurityGroups[0].VpcId' --output text)

    subnets=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=${vpc_id}" "Name=tag:Name,Values=*private*" \
        --query 'Subnets[].SubnetId' --output text \
        | tr '\t' ',') \
        || { echo "  Could not find private subnets for ${cluster_id}"; return 1; }

    # Launch the log-collector task with namespace and S3 key overrides
    echo "  Launching log-collector task..."
    local task_arn
    local run_task_output
    run_task_output=$(AWS_PAGER="" aws ecs run-task \
        --cluster "$ecs_cluster" \
        --task-definition "$task_def" \
        --launch-type FARGATE \
        --network-configuration "awsvpcConfiguration={subnets=[$subnets],securityGroups=[$sg_id],assignPublicIp=DISABLED}" \
        --overrides "{
            \"containerOverrides\": [{
                \"name\": \"log-collector\",
                \"environment\": [
                    {\"name\": \"S3_BUCKET\", \"value\": \"$s3_bucket\"},
                    {\"name\": \"INSPECT_NAMESPACES\", \"value\": \"$namespaces\"},
                    {\"name\": \"S3_KEY\", \"value\": \"$s3_key\"}
                ]
            }]
        }") \
        || { echo "  Failed to launch log-collector task for ${cluster_id}"; return 1; }

    # Check for placement failures (capacity, etc.)
    local failures
    failures=$(echo "$run_task_output" | jq -r '.failures[0].reason // empty')
    if [[ -n "$failures" ]]; then
        echo "  ECS run-task failed for ${cluster_id}: $failures"
        return 1
    fi

    task_arn=$(echo "$run_task_output" | jq -r '.tasks[0].taskArn // empty')
    if [[ -z "$task_arn" ]]; then
        echo "  ECS run-task returned no taskArn for ${cluster_id}"
        return 1
    fi

    local task_id
    task_id=$(echo "$task_arn" | awk -F'/' '{print $NF}')
    echo "  Task started: $task_id"

    # Wait for the task to complete
    echo "  Waiting for log-collector task to finish..."
    if ! aws ecs wait tasks-stopped --cluster "$ecs_cluster" --tasks "$task_id"; then
        echo "  Waiter timed out; polling task status..."
        local poll_status
        for _ in $(seq 1 6); do
            poll_status=$(aws ecs describe-tasks \
                --cluster "$ecs_cluster" --tasks "$task_id" \
                --query 'tasks[0].lastStatus' --output text 2>/dev/null)
            [[ "$poll_status" == "STOPPED" ]] && break
            sleep 10
        done
        if [[ "$poll_status" != "STOPPED" ]]; then
            echo "  Task ${task_id} still not stopped (status: ${poll_status}); giving up"
            return 1
        fi
    fi

    # Check exit code
    local describe_output exit_code
    describe_output=$(aws ecs describe-tasks \
        --cluster "$ecs_cluster" --tasks "$task_id")
    exit_code=$(echo "$describe_output" | jq -r '.tasks[0].containers[0].exitCode // empty')

    if [[ -z "$exit_code" ]]; then
        local stop_reason
        stop_reason=$(echo "$describe_output" | jq -r '.tasks[0].stoppedReason // "unknown"')
        echo "  Warning: container never started for ${cluster_id} (reason: $stop_reason)"
        echo "  Check CloudWatch logs: /ecs/${cluster_id}/bastion (log-collector stream)"
        return 1
    fi

    if [[ "$exit_code" != "0" ]]; then
        echo "  Warning: log-collector exited with code $exit_code for ${cluster_id}"
        echo "  Check CloudWatch logs: /ecs/${cluster_id}/bastion (log-collector stream)"
        return 1
    fi

    # In S3-only mode, leave logs in the bucket and print the location.
    # This is used in CI to avoid publishing sensitive data to public artifacts.
    if [[ "${S3_ONLY:-}" == "true" ]]; then
        echo "  Logs uploaded to S3. To download and extract:"
        echo ""
        echo "    mkdir -p /tmp/${cluster_id}-logs && aws s3 cp s3://${s3_bucket}/${s3_key} /tmp/${cluster_id}-logs/${s3_key} && tar xzf /tmp/${cluster_id}-logs/${s3_key} -C /tmp/${cluster_id}-logs"
        echo ""
        return 0
    fi

    # Download to a temp file outside the output directory so the unredacted
    # tarball never lands in the artifact dir.
    echo "  Downloading logs from S3..."
    local tmp_archive
    tmp_archive="$(mktemp -t inspect-logs-XXXXXX.tar.gz)"
    aws s3 cp "s3://${s3_bucket}/${s3_key}" "$tmp_archive" --quiet \
        || { echo "  Failed to download logs from S3 for ${cluster_id}"; rm -f "$tmp_archive"; return 1; }

    mkdir -p "$out_dir"
    if ! tar xzf "$tmp_archive" -C "$out_dir" --strip-components=1; then
        echo "  Failed to extract logs archive for ${cluster_id}; leaving S3 object intact"
        rm -f "$tmp_archive"
        return 1
    fi
    rm -f "$tmp_archive"

    # Clean up S3
    aws s3 rm "s3://${s3_bucket}/${s3_key}" --quiet || true

    echo "==> ${cluster_id} log collection complete: ${out_dir}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

CLUSTER_SCOPE="${1:-all}"

case "$CLUSTER_SCOPE" in
    all|regional|management) ;;
    *)
        echo "ERROR: Unknown cluster scope '${CLUSTER_SCOPE}' (expected: regional, management, or all)" >&2
        exit 1
        ;;
esac

if [[ -z "${CLUSTER_PREFIX+set}" ]]; then
    echo "ERROR: CLUSTER_PREFIX must be set (use empty string for bare cluster names)" >&2
    exit 0  # non-fatal so we don't mask test failures
fi

PREFIX="$CLUSTER_PREFIX"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_DIR="${LOG_OUTPUT_DIR:-/tmp/${PREFIX:-cluster-}logs-${TIMESTAMP}}"

echo ""
echo "Collecting cluster logs..."

failed=0

# --- Regional cluster (one per environment) ---
if [[ "$CLUSTER_SCOPE" == "all" || "$CLUSTER_SCOPE" == "regional" ]]; then
    echo ""
    if setup_aws_creds "regional"; then
        collect_logs_for_cluster "${PREFIX}regional" "$RC_NAMESPACES" "${OUTPUT_DIR}/rc" || failed=1
    else
        failed=1
    fi
fi

# --- Management clusters (dynamically discovered) ---
if [[ "$CLUSTER_SCOPE" == "all" || "$CLUSTER_SCOPE" == "management" ]]; then
    echo ""
    if setup_aws_creds "management"; then
        mc_clusters=$(discover_mc_clusters "$PREFIX")
        if [[ -z "$mc_clusters" ]]; then
            echo "  No management clusters found matching '${PREFIX}mc*'"
            failed=1
        else
            while IFS= read -r mc_id; do
                mc_name="${mc_id#"$PREFIX"}"
                collect_logs_for_cluster "$mc_id" "$MC_NAMESPACES" "${OUTPUT_DIR}/${mc_name}" || failed=1
            done <<< "$mc_clusters"
        fi
    else
        failed=1
    fi
fi

# Redact sensitive values
if [[ -d "$OUTPUT_DIR" ]]; then
    echo ""
    echo "Redacting sensitive values..."
    redact_logs "$OUTPUT_DIR"
fi

echo ""
if [[ $failed -eq 0 ]]; then
    echo "Log collection complete."
else
    echo "Log collection finished with errors. Check output above for details."
fi

exit 0
