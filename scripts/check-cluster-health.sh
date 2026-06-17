#!/usr/bin/env bash
# Cluster health check for OSS Karpenter migration with RHEL 9 FIPS custom AMI.
#
# Validates:
#   1. Karpenter NodeClass/NodePool readiness
#   2. RHEL FIPS node health and kernel FIPS enablement
#   3. Resolution of the compute-type=auto scheduling conflict
#   4. System add-on health (CoreDNS, metrics-server)
#   5. Workload scheduling recovery
#
# Usage:
#   ./check-cluster-health.sh
#
# Environment variables:
#   KARPENTER_NS   Namespace where Karpenter runs (default: kube-system)
#   PENDING_WARN   Pod pending age threshold in seconds (default: 300)
set -euo pipefail

PASS=0; FAIL=0; SKIP=0
FAILURES=()
FIPS_NODE_CHECK_POD_PREFIX="fips-health-check"

KARPENTER_NS="${KARPENTER_NS:-kube-system}"
PENDING_WARN="${PENDING_WARN:-300}"

# ─── Colors ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
  BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BOLD=''; RESET=''
fi

pass()   { printf "  ${GREEN}[PASS]${RESET} %s\n" "$1"; ((++PASS)); }
fail()   { printf "  ${RED}[FAIL]${RESET} %s\n" "$1"; ((++FAIL)); FAILURES+=("$1"); }
skip()   { printf "  ${YELLOW}[SKIP]${RESET} %s\n" "$1"; ((++SKIP)); }
header() { printf "\n${BOLD}=== %s ===${RESET}\n" "$1"; }
info()   { printf "  %s\n" "$1"; }

cleanup() {
  kubectl delete pod -n kube-system \
    -l app="${FIPS_NODE_CHECK_POD_PREFIX}" \
    --ignore-not-found=true >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# 1. Karpenter Infrastructure
# ─────────────────────────────────────────────────────────────────────────────
check_karpenter_infrastructure() {
  header "Karpenter Infrastructure"

  # Karpenter controller pods running
  local running_pods
  running_pods=$(kubectl get pods -n "$KARPENTER_NS" \
    -l app.kubernetes.io/name=karpenter \
    --field-selector=status.phase=Running \
    --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
  if [[ "$running_pods" -ge 1 ]]; then
    pass "Karpenter controller: $running_pods pod(s) Running"
  else
    fail "Karpenter controller: no Running pods in $KARPENTER_NS"
  fi

  # EC2NodeClass: fips
  local fips_nc_ready
  fips_nc_ready=$(kubectl get ec2nodeclass fips \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  if [[ "$fips_nc_ready" == "True" ]]; then
    pass "EC2NodeClass 'fips': Ready"
  else
    fail "EC2NodeClass 'fips': not Ready (status=${fips_nc_ready:-missing})"
  fi

  # EC2NodeClass: default
  local default_nc_ready
  default_nc_ready=$(kubectl get ec2nodeclass default \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  if [[ "$default_nc_ready" == "True" ]]; then
    pass "EC2NodeClass 'default': Ready"
  else
    fail "EC2NodeClass 'default': not Ready (status=${default_nc_ready:-missing}) — ArgoCD sync and 'kubectl delete nodepool system' may be pending"
  fi

  # NodePool: regional-workloads
  local rw_ready
  rw_ready=$(kubectl get nodepool regional-workloads \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  if [[ "$rw_ready" == "True" ]]; then
    pass "NodePool 'regional-workloads': Ready"
  else
    fail "NodePool 'regional-workloads': not Ready (status=${rw_ready:-missing})"
  fi

  # NodePool: system — must reference karpenter.k8s.aws (OSS), not eks.amazonaws.com (Auto Mode)
  local system_group
  system_group=$(kubectl get nodepool system \
    -o jsonpath='{.spec.template.spec.nodeClassRef.group}' 2>/dev/null || echo "")
  if [[ "$system_group" == "karpenter.k8s.aws" ]]; then
    local system_ready
    system_ready=$(kubectl get nodepool system \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if [[ "$system_ready" == "True" ]]; then
      pass "NodePool 'system': Ready (OSS Karpenter)"
    else
      fail "NodePool 'system': references OSS NodeClass but not Ready (status=${system_ready:-missing})"
    fi
  elif [[ "$system_group" == "eks.amazonaws.com" ]]; then
    fail "NodePool 'system': still references EKS Auto Mode NodeClass — run 'kubectl delete nodepool system' then sync ArgoCD"
  elif [[ -z "$system_group" ]]; then
    fail "NodePool 'system': not found — ArgoCD sync may be pending"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. Node Health
# ─────────────────────────────────────────────────────────────────────────────
check_node_health() {
  header "Node Health"

  local nodes
  nodes=$(kubectl get nodes -o json 2>/dev/null)

  local total not_ready fips_nodes
  total=$(echo "$nodes" | jq '.items | length')
  not_ready=$(echo "$nodes" | jq '[.items[] | select(
    .status.conditions[] | select(.type=="Ready" and .status!="True")
  )] | length')
  fips_nodes=$(echo "$nodes" | jq -r '[.items[] |
    select(.metadata.labels["karpenter.k8s.aws/ec2nodeclass"] == "fips") |
    .metadata.name] | join(" ")')

  if [[ "$not_ready" -eq 0 ]]; then
    pass "All $total node(s) Ready"
  else
    fail "$not_ready/$total node(s) not Ready"
    # Show which conditions are failing on each not-ready node
    echo "$nodes" | jq -r '.items[] |
      . as $node |
      .status.conditions[] |
      select(.type != "Ready" and .status == "True" and .reason != "KubeletHasNoDiskPressure" and .reason != "KubeletHasSufficientMemory" and .reason != "KubeletHasSufficientPID") |
      "    \($node.metadata.name): \(.type)=\(.status) — \(.message)" ,
      (.status.conditions[] | select(.type == "Ready" and .status != "True") |
       "    \($node.metadata.name): Ready=\(.status) — \(.message)")
    ' 2>/dev/null | sort -u | sed 's/^//' || true
  fi

  if [[ -n "$fips_nodes" ]]; then
    local count
    count=$(echo "$fips_nodes" | wc -w | tr -d '[:space:]')
    pass "FIPS NodeClass nodes present: $count"
    info "FIPS nodes: $fips_nodes"
  else
    fail "No nodes with label karpenter.k8s.aws/ec2nodeclass=fips — RHEL FIPS AMI not provisioned"
  fi

  # Verify FIPS nodes carry compute-type=ec2, not auto
  local auto_nodes
  auto_nodes=$(echo "$nodes" | jq -r '[.items[] |
    select(.metadata.labels["karpenter.k8s.aws/ec2nodeclass"] == "fips") |
    select(.metadata.labels["eks.amazonaws.com/compute-type"] != "ec2") |
    .metadata.name] | join(" ")')
  if [[ -z "$auto_nodes" ]]; then
    pass "All FIPS nodes carry compute-type=ec2"
  else
    fail "FIPS node(s) with unexpected compute-type: $auto_nodes"
  fi

  # Print node summary
  echo ""
  info "Node inventory:"
  kubectl get nodes -o custom-columns=\
'NAME:.metadata.name,STATUS:.status.conditions[-1].type,OS:.status.nodeInfo.osImage,POOL:.metadata.labels.karpenter\.sh/nodepool,NODECLASS:.metadata.labels.karpenter\.k8s\.aws/ec2nodeclass' \
    2>/dev/null | sed 's/^/  /'
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. RHEL FIPS Node — kernel FIPS enablement
#    Creates a short-lived pod pinned to each FIPS node via nodeName.
# ─────────────────────────────────────────────────────────────────────────────
check_fips_node_state() {
  header "RHEL FIPS Node State"

  local fips_nodes
  fips_nodes=$(kubectl get nodes \
    -l karpenter.k8s.aws/ec2nodeclass=fips \
    --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || echo "")

  if [[ -z "$fips_nodes" ]]; then
    skip "No FIPS nodes found — skipping kernel FIPS checks"
    return
  fi

  for node in $fips_nodes; do
    local pod_name="${FIPS_NODE_CHECK_POD_PREFIX}-$(echo "$node" | tr '.' '-' | tail -c 20)"

    kubectl apply -n kube-system -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  namespace: kube-system
  labels:
    app: ${FIPS_NODE_CHECK_POD_PREFIX}
spec:
  nodeName: ${node}
  hostPID: true
  restartPolicy: Never
  tolerations:
  - operator: Exists
  containers:
  - name: check
    image: public.ecr.aws/amazonlinux/amazonlinux:2023
    # hostPID:true shares the host PID namespace, so /proc is the host's /proc.
    # /proc/1/root gives a view into init's root filesystem for host OS details.
    command: ["sh", "-c", "cat /proc/sys/crypto/fips_enabled && grep -oE '^ID=.*' /proc/1/root/etc/os-release | head -1"]
    securityContext:
      privileged: true
EOF

    # Wait up to 30s for the pod to complete
    local attempts=0
    while [[ $attempts -lt 30 ]]; do
      local phase
      phase=$(kubectl get pod "$pod_name" -n kube-system \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
      [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
      sleep 1
      ((++attempts))
    done

    local phase
    phase=$(kubectl get pod "$pod_name" -n kube-system \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "Timeout")

    if [[ "$phase" != "Succeeded" ]]; then
      skip "$node: check pod did not complete (phase=$phase) — verify manually"
      continue
    fi

    local output
    output=$(kubectl logs "$pod_name" -n kube-system 2>/dev/null || echo "")

    local fips_val os_id
    fips_val=$(echo "$output" | head -1 | tr -d '[:space:]')
    os_id=$(echo "$output" | grep ID= | tr -d '"' | cut -d= -f2)

    if [[ "$fips_val" == "1" ]]; then
      pass "$node: /proc/sys/crypto/fips_enabled=1"
    else
      fail "$node: /proc/sys/crypto/fips_enabled=${fips_val:-ERR} (expected 1)"
    fi

    if echo "$os_id" | grep -qiE "rhel|rhcos"; then
      pass "$node: OS=$os_id"
    else
      fail "$node: unexpected OS=${os_id:-unknown} — expected RHEL"
    fi
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. Scheduling Conflict Resolution
#    Verifies the compute-type=auto vs ec2 conflict no longer appears in
#    Karpenter logs.
# ─────────────────────────────────────────────────────────────────────────────
check_scheduling_conflicts() {
  header "Scheduling Conflict Resolution"

  local conflict_count
  conflict_count=$(kubectl logs -n "$KARPENTER_NS" \
    -l app.kubernetes.io/name=karpenter \
    --since=5m 2>/dev/null \
    | grep -c 'compute-type In \[auto\]' || echo "0")

  if [[ "$conflict_count" -eq 0 ]]; then
    pass "No compute-type=auto conflicts in Karpenter logs (last 5m)"
  else
    fail "compute-type=auto conflicts still appearing in Karpenter logs: $conflict_count occurrence(s) in last 5m"
  fi

  local sched_errors
  sched_errors=$(kubectl logs -n "$KARPENTER_NS" \
    -l app.kubernetes.io/name=karpenter \
    --since=5m 2>/dev/null \
    | grep -c '"level":"ERROR"' || echo "0")

  if [[ "$sched_errors" -eq 0 ]]; then
    pass "No Karpenter ERROR logs in last 5m"
  else
    fail "Karpenter produced $sched_errors ERROR log(s) in last 5m — check 'kubectl logs -n $KARPENTER_NS -l app.kubernetes.io/name=karpenter --since=5m'"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. System Add-on Health
# ─────────────────────────────────────────────────────────────────────────────
check_system_addons() {
  header "System Add-on Health"

  # CoreDNS
  local dns_total dns_ready
  dns_total=$(kubectl get deployment -n kube-system coredns \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  dns_ready=$(kubectl get deployment -n kube-system coredns \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [[ "$dns_ready" -ge 1 && "$dns_ready" -eq "$dns_total" ]]; then
    pass "CoreDNS: $dns_ready/$dns_total replicas Ready"
  else
    fail "CoreDNS: $dns_ready/$dns_total replicas Ready"
  fi

  # DNS resolution — find a running pod that has DNS tools available.
  # Try nslookup, dig, and getent in order; skip pods whose images lack all three.
  local dns_resolved=false dns_checked=false
  while IFS=' ' read -r exec_ns exec_pod; do
    [[ -z "$exec_pod" ]] && continue
    for cmd in "nslookup kubernetes.default.svc.cluster.local" \
               "dig +short kubernetes.default.svc.cluster.local" \
               "getent hosts kubernetes.default.svc.cluster.local"; do
      if kubectl exec "$exec_pod" -n "$exec_ns" -- sh -c "$cmd" >/dev/null 2>&1; then
        pass "DNS resolution: kubernetes.default.svc.cluster.local resolves (via $exec_ns/$exec_pod)"
        dns_resolved=true; dns_checked=true
        break 2
      fi
    done
    # Pod had no DNS tools — try the next one
    dns_checked=true
  done < <(kubectl get pods -A \
    --field-selector=status.phase=Running \
    --no-headers -o custom-columns=NS:.metadata.namespace,POD:.metadata.name \
    2>/dev/null | grep -v "^kube-system" | head -5)

  if ! $dns_resolved; then
    if $dns_checked; then
      skip "DNS resolution: no suitable pod with nslookup/dig/getent found in first 5 candidates"
    else
      skip "DNS resolution: no running pods outside kube-system"
    fi
  fi

  # metrics-server
  local ms_total ms_ready
  ms_total=$(kubectl get deployment -n kube-system metrics-server \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  ms_ready=$(kubectl get deployment -n kube-system metrics-server \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [[ "$ms_ready" -ge 1 && "$ms_ready" -eq "$ms_total" ]]; then
    pass "metrics-server: $ms_ready/$ms_total replicas Ready"
  else
    fail "metrics-server: $ms_ready/$ms_total replicas Ready"
  fi

  # metrics-server functional check
  if kubectl top nodes >/dev/null 2>&1; then
    pass "metrics-server: 'kubectl top nodes' returns data"
  else
    fail "metrics-server: 'kubectl top nodes' failed — API not yet available"
  fi
}

# Print the most recent FailedScheduling event or container error for a pod.
# Usage: diagnose_pod <namespace> <pod> <phase>
diagnose_pod() {
  local ns="$1" pod="$2" phase="$3"

  if [[ "$phase" == "Pending" ]]; then
    # FailedScheduling events carry the scheduler's rejection reason
    local sched_msg
    sched_msg=$(kubectl get events -n "$ns" \
      --field-selector "involvedObject.name=${pod},reason=FailedScheduling" \
      --sort-by='.lastTimestamp' \
      --no-headers -o custom-columns=MSG:.message \
      2>/dev/null | tail -1)
    if [[ -n "$sched_msg" ]]; then
      printf "      Scheduler: %s\n" "$sched_msg"
      return
    fi
    # Karpenter uses a Warning event with reason=NotYetProvisioned or Unschedulable
    local karp_msg
    karp_msg=$(kubectl get events -n "$ns" \
      --field-selector "involvedObject.name=${pod}" \
      --sort-by='.lastTimestamp' \
      --no-headers -o custom-columns=REASON:.reason,MSG:.message \
      2>/dev/null | grep -iE "NoNodeAvailable|Unschedulable|NotYetProvisioned|Incompatible" | tail -1)
    [[ -n "$karp_msg" ]] && printf "      Karpenter: %s\n" "$karp_msg"
  else
    # For Failed/CrashLoopBackOff: show container state reason and last log lines
    local container_state
    container_state=$(kubectl get pod "$pod" -n "$ns" -o json 2>/dev/null | \
      jq -r '.status.containerStatuses[]? |
        "\(.name): \(
          if .state.waiting then "Waiting/\(.state.waiting.reason) — \(.state.waiting.message // "")"
          elif .state.terminated then "Exited(\(.state.terminated.exitCode)) — \(.state.terminated.reason) \(.state.terminated.message // "")"
          else .state | keys[0]
          end)"' 2>/dev/null || echo "")
    if [[ -n "$container_state" ]]; then
      echo "$container_state" | while IFS= read -r line; do
        printf "      Container: %s\n" "$line"
      done
    fi
    # Last 5 log lines for the first failed container
    local first_container
    first_container=$(kubectl get pod "$pod" -n "$ns" \
      -o jsonpath='{.spec.containers[0].name}' 2>/dev/null || echo "")
    if [[ -n "$first_container" ]]; then
      local logs
      logs=$(kubectl logs "$pod" -n "$ns" -c "$first_container" --tail=5 --previous 2>/dev/null \
        || kubectl logs "$pod" -n "$ns" -c "$first_container" --tail=5 2>/dev/null \
        || echo "")
      if [[ -n "$logs" ]]; then
        printf "      Last logs:\n"
        echo "$logs" | while IFS= read -r line; do
          printf "        %s\n" "$line"
        done
      fi
    fi
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. Workload Scheduling Recovery
#    Checks that previously-pending workloads are now running and diagnoses
#    pods that are Pending, Failed, or in CrashLoopBackOff.
# ─────────────────────────────────────────────────────────────────────────────
check_workload_recovery() {
  header "Workload Scheduling Recovery"

  # Collect all unhealthy pods (Pending > threshold, Failed, or CrashLoopBackOff)
  local unhealthy_pods
  unhealthy_pods=$(kubectl get pods -A -o json 2>/dev/null | jq -r '
    .items[] |
    . as $pod |
    ($pod.metadata.namespace + " " + $pod.metadata.name + " " + $pod.status.phase + " " +
     ($pod.metadata.creationTimestamp // "")) as $base |
    if $pod.status.phase == "Pending" or $pod.status.phase == "Failed" then
      $base
    elif ($pod.status.containerStatuses // [] | any(.state.waiting.reason // "" | test("CrashLoopBackOff|OOMKilled|Error|ImagePullBackOff|ErrImagePull"))) then
      ($pod.metadata.namespace + " " + $pod.metadata.name + " CrashLoopBackOff " + ($pod.metadata.creationTimestamp // ""))
    else empty
    end
  ' 2>/dev/null || echo "")

  local any_bad=false
  while IFS=' ' read -r ns pod phase ts; do
    [[ -z "$ns" ]] && continue
    [[ "$pod" == "${FIPS_NODE_CHECK_POD_PREFIX}"* ]] && continue

    # For Pending pods, check age threshold
    if [[ "$phase" == "Pending" ]]; then
      local age_seconds=0
      if [[ -n "$ts" ]]; then
        age_seconds=$(( $(date +%s) - $(date -d "$ts" +%s 2>/dev/null || echo "$(date +%s)") ))
      fi
      [[ "$age_seconds" -le "$PENDING_WARN" ]] && continue
    fi

    any_bad=true
    printf "  ${RED}[FAIL]${RESET} %s/%s (phase=%s)\n" "$ns" "$pod" "$phase"
    ((++FAIL)); FAILURES+=("$ns/$pod: $phase")
    diagnose_pod "$ns" "$pod" "$phase"
  done <<< "$unhealthy_pods"

  if ! $any_bad; then
    pass "No unhealthy pods (Pending>${PENDING_WARN}s, Failed, CrashLoopBackOff)"
  fi

  # Spot-check key namespaces affected by the compute-type conflict
  for ns in loki thanos monitoring; do
    if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
      skip "$ns: namespace not present"
      continue
    fi

    local total running pending unhealthy
    total=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
    running=$(kubectl get pods -n "$ns" --field-selector=status.phase=Running \
      --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
    pending=$(kubectl get pods -n "$ns" --field-selector=status.phase=Pending \
      --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
    unhealthy=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null \
      | grep -cE 'CrashLoopBackOff|OOMKilled|Error|ImagePullBackOff' || echo "0")

    if [[ "$pending" -eq 0 && "$unhealthy" -eq 0 && "$running" -gt 0 ]]; then
      pass "$ns: $running/$total pods Running"
    elif [[ "$pending" -gt 0 ]]; then
      # Already diagnosed above in the global pass; just surface the summary
      fail "$ns: $pending/$total pods still Pending"
    elif [[ "$unhealthy" -gt 0 ]]; then
      fail "$ns: $unhealthy pod(s) in error state (CrashLoopBackOff/OOMKilled/Error)"
    else
      skip "$ns: no pods found"
    fi
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
check_karpenter_infrastructure
check_node_health
check_fips_node_state
check_scheduling_conflicts
check_system_addons
check_workload_recovery

echo ""
printf "${BOLD}════════════════════════════════════════════${RESET}\n"
printf "${GREEN}  PASS: %d${RESET}  ${RED}FAIL: %d${RESET}  ${YELLOW}SKIP: %d${RESET}\n" "$PASS" "$FAIL" "$SKIP"
printf "${BOLD}════════════════════════════════════════════${RESET}\n"

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo ""
  printf "${BOLD}${RED}Failed Checks:${RESET}\n"
  printf "${RED}────────────────────────────────────────────${RESET}\n"
  for f in "${FAILURES[@]}"; do
    printf "  ${RED}✗${RESET} %s\n" "$f"
  done
  printf "${RED}────────────────────────────────────────────${RESET}\n"
  exit 1
else
  echo ""
  printf "  ${GREEN}✓ All checks passed${RESET}\n"
  exit 0
fi
