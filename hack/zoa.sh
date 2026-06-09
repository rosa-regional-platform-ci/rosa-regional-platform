#!/usr/bin/env bash
# ZOA CLI — Zero Operator Access shell wrapper
#
# Source this file in your .zshrc / .bashrc:
#   source /path/to/rosa-regional-platform/hack/zoa.sh
#
# Required environment:
#   ZOA_API   — API Gateway base URL (e.g. https://<id>.execute-api.<region>.amazonaws.com/prod)
#   AWS credentials (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN)
#
# All commands require -t <cluster> to specify the target.

_zoa_request() {
  local method="$1" path="$2" body="${3:-}"
  local url="${ZOA_API}/api/v0${path}"
  local region
  region=$(echo "$ZOA_API" | grep -oP '(?<=\.execute-api\.)[^.]+')

  local args=(
    -s
    --aws-sigv4 "aws:amz:${region}:execute-api"
    --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}"
    -H "x-amz-security-token: ${AWS_SESSION_TOKEN}"
    -H "Content-Type: application/json"
    -X "$method"
  )
  [[ -n "$body" ]] && args+=(-d "$body")
  args+=("$url")

  curl "${args[@]}"
}

_zoa_poll() {
  local id="$1" interval="${2:-3}" timeout="${3:-120}"
  local elapsed=0 status

  while (( elapsed < timeout )); do
    local result
    result=$(_zoa_request GET "/trusted-actions/runs/${id}")
    status=$(echo "$result" | jq -r '.status')

    case "$status" in
      succeeded|failed|error)
        echo "$result"
        return 0
        ;;
      *)
        printf "\r\033[K⠋ %s (%ds)" "$status" "$elapsed" >&2
        sleep "$interval"
        elapsed=$((elapsed + interval))
        ;;
    esac
  done

  printf "\r\033[K" >&2
  echo "error: timed out after ${timeout}s (status: ${status})" >&2
  echo "$result"
  return 1
}

zoa() {
  if [[ -z "${ZOA_API:-}" ]]; then
    echo "error: ZOA_API not set. Export your API Gateway URL:" >&2
    echo "  export ZOA_API=\"https://<id>.execute-api.<region>.amazonaws.com/prod\"" >&2
    return 1
  fi

  local cmd="${1:-help}"
  shift 2>/dev/null || true

  case "$cmd" in
    run)      _zoa_run "$@" ;;
    get)      _zoa_get "$@" ;;
    logs)     _zoa_logs "$@" ;;
    runs)     _zoa_runs "$@" ;;
    actions)  _zoa_actions "$@" ;;
    describe) _zoa_describe "$@" ;;
    help|--help|-h) _zoa_help ;;
    *)
      echo "error: unknown command '$cmd'" >&2
      _zoa_help >&2
      return 1
      ;;
  esac
}

_zoa_run() {
  local action="" target="" namespace="" all_ns="false" selector=""
  local verbose="false" resource="" name="" deployment="" pod=""
  local no_wait=false
  local -a extra_params=()

  action="${1:-}"
  [[ -z "$action" ]] && { echo "error: usage: zoa run <action> -t <cluster> [flags]" >&2; return 1; }
  shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -t|--target)     target="$2"; shift 2 ;;
      -n)              namespace="$2"; shift 2 ;;
      -A)              all_ns="true"; shift ;;
      -l)              selector="$2"; shift 2 ;;
      -v|--verbose)    verbose="true"; shift ;;
      --resource)      resource="$2"; shift 2 ;;
      --name)          name="$2"; shift 2 ;;
      --deployment)    deployment="$2"; shift 2 ;;
      --pod)           pod="$2"; shift 2 ;;
      --no-wait)       no_wait=true; shift ;;
      --param)         extra_params+=("$2"); shift 2 ;;
      *) echo "error: unknown flag '$1'" >&2; return 1 ;;
    esac
  done

  if [[ -z "$target" ]]; then
    echo "error: -t <cluster> is required" >&2
    return 1
  fi

  local params="{}"
  [[ -n "$namespace" ]]  && params=$(echo "$params" | jq --arg v "$namespace" '. + {namespace: $v}')
  [[ "$all_ns" == "true" ]] && params=$(echo "$params" | jq '. + {all_namespaces: "true"}')
  [[ -n "$selector" ]]   && params=$(echo "$params" | jq --arg v "$selector" '. + {label_selector: $v}')
  [[ "$verbose" == "true" ]] && params=$(echo "$params" | jq '. + {verbose: "true"}')
  [[ -n "$resource" ]]   && params=$(echo "$params" | jq --arg v "$resource" '. + {resource: $v}')
  [[ -n "$name" ]]       && params=$(echo "$params" | jq --arg v "$name" '. + {name: $v}')
  [[ -n "$deployment" ]] && params=$(echo "$params" | jq --arg v "$deployment" '. + {deployment_name: $v}')
  [[ -n "$pod" ]]        && params=$(echo "$params" | jq --arg v "$pod" '. + {pod_name: $v}')

  for p in "${extra_params[@]+"${extra_params[@]}"}"; do
    local key="${p%%=*}" val="${p#*=}"
    params=$(echo "$params" | jq --arg k "$key" --arg v "$val" '. + {($k): $v}')
  done

  local body
  body=$(jq -n --arg target "$target" --argjson params "$params" \
    '{target_cluster: $target} + $params')

  local submit
  submit=$(_zoa_request POST "/trusted-actions/${action}/run" "$body")

  local id
  id=$(echo "$submit" | jq -r '.id // empty')
  if [[ -z "$id" ]]; then
    echo "$submit" | jq .
    return 1
  fi

  echo "✓ ${id}" >&2

  if $no_wait; then
    echo "$submit" | jq .
    return 0
  fi

  local result
  result=$(_zoa_poll "$id")
  local rc=$?
  printf "\r\033[K" >&2

  local status
  status=$(echo "$result" | jq -r '.status')
  local duration
  duration=$(echo "$result" | jq -r '.duration_seconds // "?"')

  if [[ "$status" == "succeeded" ]]; then
    echo "✓ completed (${duration}s)" >&2
    # Fetch output
    local output
    output=$(_zoa_request GET "/trusted-actions/runs/${id}?fields=output")
    echo "$output" | jq -r '.output // empty'
  else
    echo "✗ ${status} (${duration}s)" >&2
    # Show logs on failure
    local logs
    logs=$(_zoa_request GET "/trusted-actions/runs/${id}?fields=logs")
    echo "$logs" | jq -r '.logs // .output // empty'
    return 1
  fi
}

_zoa_get() {
  local id="${1:-}"
  [[ -z "$id" ]] && { echo "error: usage: zoa get <id> [--logs|--all|--info]" >&2; return 1; }
  shift

  local fields="output"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --logs)  fields="logs"; shift ;;
      --all)   fields="output,logs"; shift ;;
      --info)  fields=""; shift ;;
      *) echo "error: unknown flag '$1'" >&2; return 1 ;;
    esac
  done

  local path="/trusted-actions/runs/${id}"
  [[ -n "$fields" ]] && path="${path}?fields=${fields}"

  _zoa_request GET "$path" | jq .
}

_zoa_logs() {
  local id="${1:-}"
  [[ -z "$id" ]] && { echo "error: usage: zoa logs <id>" >&2; return 1; }

  _zoa_request GET "/trusted-actions/runs/${id}?fields=logs" | jq -r '.logs // empty'
}

_zoa_runs() {
  local query=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -t|--target)   query="${query:+${query}&}target=$2"; shift 2 ;;
      --status)      query="${query:+${query}&}status=$2"; shift 2 ;;
      --action)      query="${query:+${query}&}action=$2"; shift 2 ;;
      --operator)    query="${query:+${query}&}operator=$2"; shift 2 ;;
      --scope)       query="${query:+${query}&}scope=$2"; shift 2 ;;
      --type)        query="${query:+${query}&}type=$2"; shift 2 ;;
      --since)       query="${query:+${query}&}since=$2"; shift 2 ;;
      --limit)       query="${query:+${query}&}limit=$2"; shift 2 ;;
      *) echo "error: unknown flag '$1'" >&2; return 1 ;;
    esac
  done

  local path="/trusted-actions/runs"
  [[ -n "$query" ]] && path="${path}?${query}"

  _zoa_request GET "$path" | jq .
}

_zoa_actions() {
  _zoa_request GET "/trusted-actions" | jq .
}

_zoa_describe() {
  local action="${1:-}"
  [[ -z "$action" ]] && { echo "error: usage: zoa describe <action>" >&2; return 1; }

  _zoa_request GET "/trusted-actions/${action}" | jq .
}

_zoa_help() {
  cat <<'EOF'
ZOA — Zero Operator Access CLI

Usage: zoa <command> [args]

Commands:
  run <action> -t <cluster> [flags]   Execute a trusted action (waits for result)
  get <id> [--logs|--all|--info]      Retrieve execution output
  logs <id>                           Show execution log
  runs [filters]                      List recent executions
  actions                             List available trusted actions
  describe <action>                   Show TA parameters and metadata

Run flags:
  -t, --target <cluster>   Target cluster (required)
  -n <namespace>           Namespace
  -A                       All namespaces
  -l <selector>            Label selector
  -v, --verbose            Full JSON output (no compact)
  --resource <type>        Resource type (get_resource)
  --name <name>            Resource name (get_resource)
  --deployment <name>      Deployment name (rollout_restart)
  --pod <name>             Pod name (delete_pod)
  --no-wait                Don't wait for completion (print ID only)
  --param key=value        Pass arbitrary param

Runs filters (all combinable):
  -t, --target <cluster>   Filter by target cluster
  --status <status>        Filter by status (pending|running|succeeded|failed|timed_out)
  --action <name>          Filter by action name
  --operator <name>        Filter by operator
  --scope <scope>          Filter by scope (kube-api|aws)
  --type <type>            Filter by type (read|write)
  --since <duration>       Filter by time (e.g. 1h, 24h, 7d)
  --limit <n>              Max results (default 20, max 100)

Get flags:
  --logs                   Show logs instead of output
  --all                    Show output + logs + metadata
  --info                   Show metadata only (status, timing)

Environment:
  ZOA_API                  API Gateway URL (required)
  AWS_ACCESS_KEY_ID        AWS credentials (required)
  AWS_SECRET_ACCESS_KEY    AWS credentials (required)
  AWS_SESSION_TOKEN        AWS session token (required for assumed roles)

Examples:
  zoa run get_nodes -t mc-useast1-1
  zoa run get_pods -t mc-useast1-1 -n maestro -l app=maestro
  zoa run get_pods -t mc-useast1-1 -A | jq '.[] | select(.status != "Running")'
  zoa run get_resource -t mc-useast1-1 --resource deployments -A
  zoa run rollout_restart -t mc-useast1-1 -n maestro --deployment maestro
  zoa get 8d8ced24
  zoa logs 8d8ced24
  zoa runs -t mc-useast1-1 --since 1h
  zoa runs --status failed --since 24h
  zoa runs --action rollout_restart --operator slopezma
EOF
}
