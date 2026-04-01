#!/usr/bin/env bash
#
# Integration environment CLI for ROSA Regional Platform.
#
# Provides interactive access to the standing integration environment.
# Uses AWS profiles with SAML authentication (via rosa-regional-platform-internal).
#
# Typically invoked via Makefile targets (make int-shell, etc.)
#
# The script constructs a temporary AWS config with the int profiles.
# It discovers rosa-regional-platform-internal as a sibling directory,
# or you can set INTERNAL_REPO to override.

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

CONTAINER_ENGINE="${CONTAINER_ENGINE:-$(command -v podman 2>/dev/null || command -v docker 2>/dev/null || true)}"
CI_IMAGE="rosa-regional-ci"

INT_REGION="us-east-1"
RC_CLUSTER="regional"
MC_CLUSTER="mc01"

VAULT_ADDR="https://vault.ci.openshift.org"
VAULT_KV_MOUNT="kv"
VAULT_SECRET_PATH="selfservice/cluster-secrets-rosa-regional-platform-int/integration-creds"
VAULT_ACCOUNTS_FIELD="int_accounts"

# =============================================================================
# Helpers
# =============================================================================

die() { echo "Error: $*" >&2; exit 1; }

usage() {
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  shell           Interactive shell for Platform API access"
    echo "  bastion         Connect to RC/MC bastion"
    echo "  port-forward    Forward ports through RC/MC bastion"
    echo "  e2e             Run e2e tests"
    echo "  collect-logs    Collect kubernetes logs from RC/MC"
}

usage_bastion() {
    echo "Usage: $0 bastion --cluster-type [value]"
    echo ""
    echo "Connect to RC/MC bastion in the integration environment"
    echo ""
    echo "Flags:"
    echo "  --cluster-type  Cluster type: \"regional\" or \"management\""
}

usage_port_forward() {
    echo "Usage: $0 port-forward --cluster-type [value] [--all | --service <name>]"
    echo ""
    echo "Opens port forwards to services running on a cluster"
    echo ""
    echo "Flags:"
    echo "  --all              Automatically open all port forwards"
    echo "  --service <name>   Forward a specific service (maestro, argocd, prometheus)"
    echo "  --cluster-type     Cluster type: \"regional\" or \"management\""
}

cluster_id_for() {
    case "$1" in
        regional)   echo "$RC_CLUSTER" ;;
        management) echo "$MC_CLUSTER" ;;
        *)          die "Unknown cluster type: $1" ;;
    esac
}

profile_for() {
    case "$1" in
        regional)   echo "rrp-int-rc" ;;
        management) echo "rrp-int-mc" ;;
        *)          die "Unknown cluster type: $1" ;;
    esac
}

# Fetch config from Vault via OIDC login.
# Sets: CENTRAL_ACCOUNT, RC_ACCOUNT, MC_ACCOUNT, INT_API_URL
fetch_vault_config() {
    echo "Fetching config from Vault (OIDC login)..."

    local vault_token
    vault_token=$(VAULT_ADDR="$VAULT_ADDR" vault login -method=oidc -token-only 2>/dev/null) \
        || die "Vault OIDC login failed."

    local accounts_json
    accounts_json=$(VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$vault_token" \
        vault kv get -mount="$VAULT_KV_MOUNT" -field="$VAULT_ACCOUNTS_FIELD" "$VAULT_SECRET_PATH" 2>/dev/null) \
        || die "Failed to fetch '$VAULT_ACCOUNTS_FIELD' from Vault."

    CENTRAL_ACCOUNT=$(echo "$accounts_json" | jq -r '.central') \
        || die "Failed to parse 'central' from account IDs."
    RC_ACCOUNT=$(echo "$accounts_json" | jq -r '.rc') \
        || die "Failed to parse 'rc' from account IDs."
    MC_ACCOUNT=$(echo "$accounts_json" | jq -r '.mc') \
        || die "Failed to parse 'mc' from account IDs."

    [[ "$CENTRAL_ACCOUNT" != "null" ]] || die "Missing 'central' in account IDs."
    [[ "$RC_ACCOUNT" != "null" ]]      || die "Missing 'rc' in account IDs."
    [[ "$MC_ACCOUNT" != "null" ]]       || die "Missing 'mc' in account IDs."

    INT_API_URL=$(VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$vault_token" \
        vault kv get -mount="$VAULT_KV_MOUNT" -field="api_url" "$VAULT_SECRET_PATH" 2>/dev/null) \
        || die "Failed to fetch 'api_url' from Vault."

    echo "Vault config loaded."
}

# Create temporary AWS config with int profiles.
# The credential_process calls into rosa-regional-platform-internal for SAML auth.
setup_aws_config() {
    local internal_repo="${INTERNAL_REPO:-$(cd "$REPO_ROOT/../rosa-regional-platform-internal" 2>/dev/null && pwd || true)}"
    [[ -n "$internal_repo" ]] \
        || die "rosa-regional-platform-internal not found at $REPO_ROOT/../rosa-regional-platform-internal. Set INTERNAL_REPO."
    [[ -d "$internal_repo/infra/scripts" ]] \
        || die "Cannot find infra/scripts/ in $internal_repo"

    fetch_vault_config

    _aws_config_dir=$(mktemp -d)
    export AWS_CONFIG_FILE="$_aws_config_dir/config"
    export AWS_SHARED_CREDENTIALS_FILE="$_aws_config_dir/credentials"
    touch "$AWS_SHARED_CREDENTIALS_FILE"

    cat > "$AWS_CONFIG_FILE" <<AWSCFG
[profile rrp-int-admin]
credential_process = uv run --project ${internal_repo}/infra/scripts python ${internal_repo}/infra/scripts/cached_saml_credentials_process.py ${CENTRAL_ACCOUNT} ${CENTRAL_ACCOUNT}-rrp-int-admin
region = ${INT_REGION}

[profile rrp-int-rc]
role_arn = arn:aws:iam::${RC_ACCOUNT}:role/OrganizationAccountAccessRole
source_profile = rrp-int-admin
region = ${INT_REGION}

[profile rrp-int-mc]
role_arn = arn:aws:iam::${MC_ACCOUNT}:role/OrganizationAccountAccessRole
source_profile = rrp-int-admin
region = ${INT_REGION}
AWSCFG

    echo "AWS config written to: $AWS_CONFIG_FILE"
    trap "rm -rf '${_aws_config_dir}'" EXIT
}

# Resolve temporary credentials from an AWS profile for container injection.
# Sets: _CRED_AK, _CRED_SK, _CRED_ST
resolve_creds() {
    local profile="$1"
    echo "Resolving credentials for profile $profile..."
    local creds
    creds=$(aws configure export-credentials --profile "$profile" --format process 2>/dev/null) \
        || die "Failed to resolve credentials for profile $profile. Have you authenticated?"
    _CRED_AK=$(echo "$creds" | jq -r '.AccessKeyId')
    _CRED_SK=$(echo "$creds" | jq -r '.SecretAccessKey')
    _CRED_ST=$(echo "$creds" | jq -r '.SessionToken // empty')
}

# Build the CI container image if not already present.
ensure_image() {
    [[ -n "$CONTAINER_ENGINE" ]] \
        || die "No container engine found. Install podman or docker."

    if ! $CONTAINER_ENGINE image inspect "$CI_IMAGE" >/dev/null 2>&1; then
        echo "Building CI image..."
        local build_output
        if ! build_output=$($CONTAINER_ENGINE build -t "$CI_IMAGE" -f ci/Containerfile ci 2>&1); then
            echo "$build_output"
            die "Failed to build CI image."
        fi
    fi
}

# =============================================================================
# Bastion helpers (shared by bastion + port-forward)
# =============================================================================

bastion_setup() {
    local cluster_type="$1"
    local cluster_id profile

    cluster_id=$(cluster_id_for "$cluster_type")
    profile=$(profile_for "$cluster_type")
    export ecs_cluster="${cluster_id}-bastion"

    setup_aws_config
    export AWS_PROFILE="$profile"
    export AWS_DEFAULT_REGION="$INT_REGION"
    export AWS_REGION="$INT_REGION"

    echo "Connecting to integration bastion..."
    echo "  Cluster type: $cluster_type"
    echo "  Cluster ID:   $cluster_id"
    echo "  ECS cluster:  $ecs_cluster"
    echo "  Region:       $INT_REGION"
    echo ""

    # Check for an existing running task
    echo "==> Checking for running bastion tasks..."
    local existing_task
    existing_task=$(aws ecs list-tasks --cluster "$ecs_cluster" \
        --desired-status RUNNING --query 'taskArns[0]' --output text 2>/dev/null || true)

    if [[ -n "$existing_task" && "$existing_task" != "None" ]]; then
        export task_id=$(echo "$existing_task" | awk -F'/' '{print $NF}')
        echo "==> Found existing running task: $task_id"
    else
        echo "==> No running task found, starting a new one..."

        local task_def="${cluster_id}-bastion"
        local sg_id subnets vpc_id

        sg_id=$(aws ec2 describe-security-groups \
            --filters "Name=group-name,Values=${cluster_id}-bastion" \
            --query 'SecurityGroups[0].GroupId' --output text) \
            || die "Could not find security group '${cluster_id}-bastion'."
        [[ "$sg_id" != "None" ]] \
            || die "Security group '${cluster_id}-bastion' not found."

        vpc_id=$(aws ec2 describe-security-groups \
            --group-ids "$sg_id" \
            --query 'SecurityGroups[0].VpcId' --output text)

        subnets=$(aws ec2 describe-subnets \
            --filters "Name=vpc-id,Values=${vpc_id}" "Name=tag:Name,Values=*private*" \
            --query 'Subnets[].SubnetId' --output text \
            | tr '\t' ',') \
            || die "Could not find private subnets in VPC $vpc_id."

        echo "    Task def:  $task_def"
        echo "    SG:        $sg_id"
        echo "    Subnets:   $subnets"

        AWS_PAGER="" aws ecs run-task \
            --cluster "$ecs_cluster" \
            --task-definition "$task_def" \
            --launch-type FARGATE \
            --enable-execute-command \
            --network-configuration "awsvpcConfiguration={subnets=[$subnets],securityGroups=[$sg_id],assignPublicIp=DISABLED}" \
            > /dev/null

        export task_id=$(aws ecs list-tasks --cluster "$ecs_cluster" \
            --query 'taskArns[0]' --output text | awk -F'/' '{print $NF}')
    fi

    # Wait for task to be running
    echo "==> Waiting for task to be running..."
    aws ecs wait tasks-running --cluster "$ecs_cluster" --tasks "$task_id"

    # Wait for the ECS exec agent to be ready
    echo "==> Waiting for execute command agent..."
    local agent_status=""
    for i in $(seq 1 30); do
        agent_status=$(aws ecs describe-tasks \
            --cluster "$ecs_cluster" --tasks "$task_id" --output json \
            | jq -r '.tasks[0].containers[] | select(.name=="bastion") | .managedAgents[] | select(.name=="ExecuteCommandAgent") | .lastStatus' 2>/dev/null || true)
        if [[ "$agent_status" == "RUNNING" ]]; then
            break
        fi
        sleep 2
    done
    [[ "$agent_status" == "RUNNING" ]] \
        || die "Execute command agent did not become ready (status: ${agent_status:-unknown})"
}

# =============================================================================
# Commands
# =============================================================================

cmd_shell() {
    setup_aws_config

    local api_url="${API_URL:-$INT_API_URL}"
    resolve_creds "rrp-int-rc"

    local cred_flags="-e AWS_ACCESS_KEY_ID=$_CRED_AK -e AWS_SECRET_ACCESS_KEY=$_CRED_SK"
    [[ -z "$_CRED_ST" ]] || cred_flags="$cred_flags -e AWS_SESSION_TOKEN=$_CRED_ST"

    # shellcheck disable=SC2086
    $CONTAINER_ENGINE run --rm -it \
        $cred_flags \
        -e "AWS_DEFAULT_REGION=$INT_REGION" \
        -e "AWS_REGION=$INT_REGION" \
        -e "API_URL=$api_url" \
        "$CI_IMAGE" \
        bash -c '
            echo ""
            echo "ROSA Regional Platform — Integration Environment"
            echo ""
            echo "Region:      $AWS_DEFAULT_REGION"
            echo "API Gateway: $API_URL"
            echo ""
            echo "Example commands:"
            echo "  awscurl --service execute-api \$API_URL/v0/live"
            exec bash'
}

cmd_bastion() {
    local cluster_type

    while [ "${1:-}" != "" ]; do
        case $1 in
            --cluster-type )    cluster_type=${2:-}
                                shift
                                ;;
            --help )            usage_bastion
                                exit 0
                                ;;
            * ) echo "Unexpected parameter $1"
                usage_bastion
                exit 1
        esac
        shift
    done

    case "$cluster_type" in
      regional|management) ;;
      *) echo "Error: invalid cluster type '${cluster_type:-}'"; echo ""; usage_bastion; exit 1 ;;
    esac

    bastion_setup "$cluster_type"

    echo ""
    echo "==> Bastion task ready"
    echo "    ECS cluster: $ecs_cluster"
    echo "    Task ID:     $task_id"
    echo ""
    echo "==> Connecting to bastion..."
    echo ""

    aws ecs execute-command \
        --cluster "$ecs_cluster" \
        --task "$task_id" \
        --container bastion \
        --interactive \
        --command '/bin/bash'
}

cmd_port_forward() {
    local all_svcs=false
    local cluster_type
    local SERVICE=""

    while [ "${1:-}" != "" ]; do
    case $1 in
        --all )                 all_svcs=true
                                ;;
        --service )             SERVICE="${2:-}"
                                shift
                                ;;
        --cluster-type )        cluster_type=${2:-}
                                shift
                                ;;
        --help )                usage_port_forward
                                exit 0
                                ;;
        * ) echo "Unexpected parameter $1"
            usage_port_forward
            exit 1
    esac
    shift
    done

    case "$cluster_type" in
      regional|management) ;;
      *) echo "Error: invalid cluster type '${cluster_type:-}'"; echo ""; usage_port_forward; exit 1 ;;
    esac

    local maestro="maestro   - Maestro HTTP + gRPC"
    local argocd="argocd    - ArgoCD server HTTPS"
    local prometheus="prometheus  - Prometheus Monitoring Dashboard"

    local regional_svc_list=("$maestro" "$argocd" "$prometheus")
    local management_svc_list=("$argocd" "$prometheus")

    local services

    if [ $all_svcs == true ]; then
        case "$cluster_type" in
            regional )      services=$(printf '%s\n' "${regional_svc_list[@]}") ;;
            management )    services=$(printf '%s\n' "${management_svc_list[@]}") ;;
        esac
    elif [[ -n "$SERVICE" ]]; then
        services="$SERVICE"
    elif command -v fzf >/dev/null 2>&1; then
        if [ "$cluster_type" = "regional" ]; then
            services=$(printf '%s\n' "${regional_svc_list[@]}" \
                | fzf --multi --height=10 --layout=reverse --header="Select service (${cluster_type}):" --no-info)
        else
            services=$(printf '%s\n' "${management_svc_list[@]}" \
                | fzf --multi --height=10 --layout=reverse --header="Select service (${cluster_type}):" --no-info)
        fi
        [[ -n "$services" ]] || { echo "Aborted."; exit 1; }
    else
        die "Use --all, --service <name>, or install fzf for interactive selection."
    fi
    services=$(awk '{print $1}' <<< "$services" | tr '\n' ' ')

    local forwards=()
    for service in $services
    do
        if [ "$service" = "maestro" ] && [ "$cluster_type" != "regional" ]; then
            echo "Error: maestro is only available on regional clusters."
            exit 1
        fi

        case "$service" in
        maestro)
            forwards+=(
            "Maestro-HTTP 8080 8080 maestro-http maestro-server 8080"
            "Maestro-gRPC 8090 8090 maestro-grpc maestro-server 8090"
            )
            ;;
        argocd)
            forwards+=(
            "ArgoCD-Server 8443 8443 argocd-server argocd 443"
            )
            ;;
        prometheus)
            forwards+=(
            "Prometheus 9090 9090 monitoring-prometheus monitoring 9090"
            )
            ;;
        *) echo "Error: unknown service '$service'"; exit 1 ;;
        esac
    done

    # Check local ports are free
    for entry in "${forwards[@]}"; do
        local local_port
        read -r label _ local_port _ _ _ <<< "$entry"
        if lsof -iTCP:"$local_port" -sTCP:LISTEN -t &>/dev/null; then
            echo "Error: Local port ${local_port} (${label}) is already in use."
            echo "Kill the process using it first: lsof -iTCP:${local_port} -sTCP:LISTEN"
            exit 1
        fi
    done

    bastion_setup "$cluster_type"

    local runtime_id
    runtime_id=$(aws ecs describe-tasks \
      --cluster "$ecs_cluster" \
      --tasks "$task_id" \
      --query 'tasks[0].containers[?name==`bastion`].runtimeId | [0]' \
      --output text)

    if [[ -z "$runtime_id" || "$runtime_id" == "None" ]]; then
      echo "Error: runtime_id not found for task '$task_id' in cluster '$ecs_cluster'"
      exit 1
    fi

    echo ""
    echo "==> Bastion task ready"
    echo "    ECS cluster: $ecs_cluster"
    echo "    Task ID:     $task_id"
    echo ""
    echo "==> Connecting to bastion..."
    echo ""

    ssm_pids=()
    bastion_pids=()

    # Chain with the existing EXIT trap (setup_aws_config cleanup)
    _prev_trap=$(trap -p EXIT | sed "s/^trap -- '//;s/' EXIT$//")
    cleanup() {
    echo ""
    echo "Stopping all port-forward sessions..."
    for pid in "${ssm_pids[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    for pid in "${bastion_pids[@]}"; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    eval "$_prev_trap"
    }
    trap cleanup EXIT

    target="ecs:${ecs_cluster}_${task_id}_${runtime_id}"

    # Kill stale port-forwards on bastion
    echo "==> Cleaning up stale port-forwards on bastion..."
    aws ecs execute-command \
    --cluster "$ecs_cluster" \
    --task "$task_id" \
    --container bastion \
    --interactive \
    --command "pkill -f kubectl.port-forward || true" &>/dev/null || true
    sleep 2

    # Start kubectl port-forward(s) inside the bastion
    for entry in "${forwards[@]}"; do
        read -r label remote_port local_port k8s_svc k8s_ns k8s_svc_port <<< "$entry"

        echo "==> [bastion] kubectl port-forward svc/${k8s_svc} ${remote_port}:${k8s_svc_port} -n ${k8s_ns}"
        aws ecs execute-command \
            --cluster "$ecs_cluster" \
            --task "$task_id" \
            --container bastion \
            --interactive \
            --command "kubectl port-forward svc/${k8s_svc} ${remote_port}:${k8s_svc_port} -n ${k8s_ns} --address 0.0.0.0" &
        bastion_pids+=($!)
    done

    echo ""
    echo "==> Waiting for kubectl port-forward(s) to be ready..."
    sleep 5

    # SSM port forward from laptop to bastion
    for entry in "${forwards[@]}"; do
        read -r label remote_port local_port _ _ _ <<< "$entry"

        echo "==> [local] SSM forwarding ${label} (localhost:${local_port} -> bastion:${remote_port})..."
        aws ssm start-session \
            --target "$target" \
            --document-name AWS-StartPortForwardingSession \
            --parameters "{\"portNumber\":[\"${remote_port}\"],\"localPortNumber\":[\"${local_port}\"]}" &
        ssm_pids+=($!)
    done

    echo ""
    echo "==> Port forwarding active. Forwarded ports:"
    for entry in "${forwards[@]}"; do
        read -r label _ local_port _ _ _ <<< "$entry"
        echo "    ${label}: http://localhost:${local_port}"
    done

    # For ArgoCD, fetch and display the admin password from the bastion.
    if [[ " $services " =~ " argocd " ]]; then
        echo ""
        echo "==> Fetching ArgoCD admin password..."
        argocd_get_password=$(aws ecs execute-command \
            --cluster "$ecs_cluster" \
            --task "$task_id" \
            --container bastion \
            --interactive \
            --command "sh -c \"echo ARGOCD_PW=\$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath={.data.password} | base64 -d)\"" 2>/dev/null || true)
        argocd_password=$(echo "$argocd_get_password" | grep -o 'ARGOCD_PW=.*' | cut -d= -f2 | tr -d '[:space:]')
        echo ""
        echo "    ArgoCD UI:       https://localhost:8443"
        echo "    Username:        admin"
        if [ -n "$argocd_password" ]; then
            echo "    Password:        ${argocd_password}"
        else
            echo "    Password:        (could not retrieve - run on bastion manually):"
            echo "                     kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath={.data.password} | base64 -d"
        fi
    fi

    echo ""
    echo "Press Ctrl+C to stop."

    while true; do
    for pid in "${ssm_pids[@]}"; do
        if ! kill -0 "$pid" 2>/dev/null; then
        wait "$pid" 2>/dev/null || true
        echo ""
        echo "Error: SSM port-forward session (PID $pid) exited unexpectedly."
        exit 1
        fi
    done
    sleep 2
    done
}

cmd_e2e() {
    local e2e_ref="${E2E_REF:-main}"
    local e2e_repo="${E2E_REPO:-https://github.com/openshift-online/rosa-regional-platform-api.git}"

    setup_aws_config

    local api_url="${API_URL:-$INT_API_URL}"
    resolve_creds "rrp-int-rc"

    echo "Running e2e tests..."
    echo "  API_URL:    $api_url"
    echo "  REGION:     $INT_REGION"
    echo "  E2E_REF:    $e2e_ref"
    echo "  E2E_REPO:   $e2e_repo"

    $CONTAINER_ENGINE run --rm \
        -v "${REPO_ROOT}:/workspace:ro,z" \
        -w /workspace \
        -e "BASE_URL=$api_url" \
        -e "AWS_ACCESS_KEY_ID=$_CRED_AK" \
        -e "AWS_SECRET_ACCESS_KEY=$_CRED_SK" \
        ${_CRED_ST:+-e "AWS_SESSION_TOKEN=$_CRED_ST"} \
        -e "AWS_DEFAULT_REGION=$INT_REGION" \
        -e "AWS_REGION=$INT_REGION" \
        -e "E2E_REF=$e2e_ref" \
        -e "E2E_REPO=$e2e_repo" \
        "$CI_IMAGE" \
        bash ci/e2e-tests.sh
}

cmd_collect_logs() {
    local cluster_type="${1:-all}"
    case "$cluster_type" in
        rc) cluster_type="regional" ;;
        mc) cluster_type="management" ;;
    esac

    setup_aws_config

    # Resolve credentials for both accounts
    resolve_creds "rrp-int-rc"
    export REGIONAL_AK="$_CRED_AK"
    export REGIONAL_SK="$_CRED_SK"
    ${_CRED_ST:+export REGIONAL_ST="$_CRED_ST"}

    resolve_creds "rrp-int-mc"
    export MANAGEMENT_AK="$_CRED_AK"
    export MANAGEMENT_SK="$_CRED_SK"
    ${_CRED_ST:+export MANAGEMENT_ST="$_CRED_ST"}

    export AWS_REGION="$INT_REGION"
    export CLUSTER_PREFIX=""
    if [[ -n "${ARTIFACT_DIR:-}" ]]; then
        export LOG_OUTPUT_DIR="$ARTIFACT_DIR"
    fi

    "${REPO_ROOT}/scripts/dev/collect-cluster-logs.sh" "$cluster_type"
}

# =============================================================================
# Main
# =============================================================================

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# All commands need vault + jq for account ID fetch
case "${1:-help}" in
    bastion)
        for tool in vault jq uv aws; do
            command -v "$tool" >/dev/null 2>&1 || die "Missing required tool: $tool"
        done
        ;;
    port-forward)
        for tool in vault jq uv aws lsof; do
            command -v "$tool" >/dev/null 2>&1 || die "Missing required tool: $tool"
        done
        ;;
    shell|e2e)
        for tool in vault jq uv aws; do
            command -v "$tool" >/dev/null 2>&1 || die "Missing required tool: $tool"
        done
        ensure_image
        ;;
    collect-logs)
        for tool in vault jq uv aws; do
            command -v "$tool" >/dev/null 2>&1 || die "Missing required tool: $tool"
        done
        ;;
esac

case "${1:-help}" in
    shell)          cmd_shell ;;
    bastion)        shift; cmd_bastion "$@" ;;
    port-forward)   shift; cmd_port_forward "$@" ;;
    e2e)            cmd_e2e ;;
    collect-logs)   shift; cmd_collect_logs "$@" ;;
    help|*)
        usage
        ;;
esac
