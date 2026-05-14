# FIPS-Only Compute for EKS Auto Mode

**Last Updated Date**: 2026-05-14

## Summary

All EKS clusters in the ROSA Regional Platform use two custom Karpenter NodePools referencing a FIPS-validated NodeClass, with EKS Auto Mode's built-in node pools disabled (`node_pools = []`). This is the AWS-validated pattern for achieving exclusively FIPS-validated compute in EKS Auto Mode while preserving full operational functionality.

## Context

FedRAMP High/Moderate authorization requires that all cryptographic operations use FIPS 140-2 or FIPS 140-3 validated modules. On EKS, this means every compute node must run a FIPS-validated operating system — specifically Bottlerocket with FIPS mode enabled.

- **Problem Statement**: EKS Auto Mode's built-in node pools (`system` and `general-purpose`) provision standard (non-FIPS) Bottlerocket AMIs. Using these pools for any workloads violates the FedRAMP cryptographic module requirement. Disabling them with `node_pools = []` is necessary but introduces a bootstrap deadlock: EKS Auto Mode pre-installs CoreDNS and metrics-server as managed addons with hard node affinity for the built-in `system` pool. With that pool absent, both addons are permanently Pending, blocking Karpenter from provisioning any nodes (Karpenter is reactive — it only creates nodes in response to unschedulable pods that match a NodePool), and preventing cluster bootstrap.
- **Constraints**:
  - EKS Auto Mode's built-in node pools cannot be patched to reference a custom NodeClass. AWS auto-reverts any modifications to return them to their managed defaults.
  - EKS Auto Mode manages CoreDNS and metrics-server as pre-installed addons. Their scheduling constraints (`karpenter.sh/nodepool: system` affinity) are not user-configurable.
  - The cluster bootstrap (ArgoCD install, root Application creation) runs inside an ECS Fargate task in a private subnet, with no public cluster API access. See [ECS Fargate Bootstrap for Fully Private EKS Clusters](./fully-private-eks-bootstrap.md).
- **Assumptions**: EKS Auto Mode is retained for operational simplicity (managed control plane, embedded Karpenter, automatic node lifecycle management) and AWS support coverage. Self-managed Karpenter is not a preferred alternative.

## Alternatives Considered

1. **Keep built-in node pools enabled**: Retain `node_pools = ["system", "general-purpose"]` and accept that some nodes run non-FIPS AMIs. Straightforward to operate but directly violates the FedRAMP cryptographic module requirement. Rejected.

2. **Patch built-in node pools to use a FIPS NodeClass**: Attempt to modify the built-in `system` pool to reference a custom NodeClass with `advancedSecurity.fips: true`. AWS Auto Mode auto-reverts any user modifications to built-in pools within minutes, making this approach non-durable. Rejected.

3. **Replace EKS Auto Mode with self-managed Karpenter**: Disable Auto Mode, install Karpenter as a workload, and manage all node lifecycle manually. This eliminates the built-in pool constraint but loses Auto Mode's managed node lifecycle, automatic version upgrades, and unified support. Significantly increases operational complexity. Rejected.

4. **Disable built-in pools and manually patch CoreDNS affinity**: Set `node_pools = []` and edit the CoreDNS addon configuration to remove the `karpenter.sh/nodepool: system` node affinity. EKS-managed addon scheduling constraints are not user-configurable — changes are overridden by the addon manager. Rejected.

5. **Two custom FIPS NodePools with built-in pools disabled**: Set `node_pools = []` and create two Karpenter NodePools (`system-fips` and `*-workloads`) both referencing a FIPS NodeClass. The `system-fips` pool carries the `CriticalAddonsOnly:NoSchedule` taint, which CoreDNS and metrics-server tolerate, satisfying their scheduling requirements without the `karpenter.sh/nodepool: system` constraint. **Chosen.**

## Design Rationale

- **Justification**: The two-NodePool approach is the AWS-documented pattern for FIPS-only EKS Auto Mode. It satisfies every constraint: all nodes are provisioned from a FIPS NodeClass (Bottlerocket FIPS AMI), CoreDNS and metrics-server schedule successfully (via taint toleration rather than pool affinity), and the cluster can be bootstrapped without requiring changes to EKS-managed addon configuration.

- **Evidence**: AWS introduced FIPS support for EKS Auto Mode in October 2025 via the `eks.amazonaws.com/v1` NodeClass `advancedSecurity` field. The `fips: true` flag provisions Bottlerocket nodes with the FIPS kernel and validated cryptographic libraries. The `kernelLockdown: Integrity` setting enforces kernel integrity protection. Both fields are required for FIPS compliance. The two-NodePool pattern (system + workloads) mirrors the structure of the built-in pools it replaces.

- **Comparison**: Alternatives 1 and 2 fail the FedRAMP requirement directly. Alternative 3 achieves FIPS compliance but at the cost of significant operational complexity that conflicts with the platform's operational simplicity goal. Alternative 4 is technically infeasible due to addon manager overrides. Alternative 5 (chosen) achieves compliance with the same operational model and no additional infrastructure dependencies.

## Consequences

### Positive

- All cluster compute nodes run Bottlerocket with FIPS-validated cryptographic modules, satisfying FedRAMP High/Moderate cryptographic requirements.
- The `system-fips` / `*-workloads` NodePool split provides a clean separation between system addon scheduling and platform workload scheduling, improving blast radius isolation.
- Both NodePools reference a single FIPS NodeClass, ensuring consistent FIPS configuration with a single point of update.
- The NodeClass and NodePools are applied by the ECS bootstrap task and subsequently adopted by ArgoCD on first sync, making them GitOps-managed like all other cluster configuration.
- The approach is forward-compatible: as AWS expands FIPS Auto Mode capabilities (e.g., additional architectures, instance families), only the NodeClass/NodePool specs need updating.

### Negative

- EKS Auto Mode enforces a mandatory 21-day maximum node lifetime. All nodes are replaced on a rolling schedule. Stateful workloads that cannot tolerate pod eviction (Thanos, Grafana) must have `PodDisruptionBudgets` configured to prevent data loss or availability gaps during rotation.
- Bootstrap sequencing is non-trivial: the ECS task must apply NodeClass/NodePools, trigger Karpenter by creating the CoreDNS and metrics-server addons (which produce pending pods), wait for a FIPS node to become Ready, then wait for addons to become Active before proceeding with ArgoCD installation. A failure in any step aborts the bootstrap.
- Adding a cluster type (beyond `management-cluster` and `regional-cluster`) requires updating the bootstrap script's `NODEPOOL_NAME` selection logic.

## Cross-Cutting Concerns

### Reliability

- **Scalability**: The `system-fips` NodePool is intentionally small (8 CPU / 32 GiB) to limit blast radius for system addon scaling. The `*-workloads` NodePool is large (64 CPU / 256 GiB) and handles all platform and application workloads. Both use `consolidationPolicy: WhenEmpty` to release idle capacity promptly.
- **Observability**: Karpenter NodeClaims are visible via `kubectl get nodeclaims`. Bootstrap failure diagnostics in the ECS task log node state, pending NodeClaims, and pending pods in `kube-system` to pinpoint scheduling failures. CloudWatch logs for the ECS task provide a full audit trail.
- **Resiliency**: Node provisioning is Karpenter-managed and automatic. The mandatory 21-day rotation means PodDisruptionBudgets are load-bearing for stateful workloads — their absence is a reliability risk, not just a compliance gap.

### Security

- All nodes use Bottlerocket with `advancedSecurity.fips: true` and `kernelLockdown: Integrity`, satisfying FIPS 140-2/140-3 requirements for cryptographic modules (SC-13) and providing kernel integrity enforcement.
- The FIPS NodeClass (`eks.amazonaws.com/v1`) selects subnets and security groups via cluster-owned tags, ensuring nodes land in the correct private subnets with the correct network policies.
- The `system-fips` NodePool's `CriticalAddonsOnly:NoSchedule` taint prevents non-system workloads from being scheduled on system nodes without an explicit toleration.
- Node IAM role (`${cluster_id}-auto-node-role`) is referenced directly in the NodeClass, scoping node permissions to a cluster-specific role rather than a shared role.

### Performance

- FIPS-mode Bottlerocket has negligible performance overhead for general-purpose workloads. Cryptographic operations on FIPS-validated paths may be slightly slower than non-FIPS equivalents, but this is acceptable given the compliance requirement.
- `consolidateAfter: 60s` on both NodePools enables rapid scale-down of idle nodes, reducing cost and attack surface.

### Cost

- Two NodePools instead of one adds no direct cost — NodePools are Karpenter configuration objects with no AWS billing. Node costs are identical: on-demand EC2 instances running Bottlerocket.
- `WhenEmpty` consolidation reclaims idle capacity on the `system-fips` pool when CoreDNS and metrics-server scale down replicas (e.g., off-peak), reducing EC2 spend.

### Operability

- The FIPS NodeClass and both NodePools are created by the ECS bootstrap task on first run and subsequently managed by ArgoCD. Day-2 changes are made via GitOps — no manual `kubectl apply` is required.
- The 21-day mandatory rotation is fully automatic. Operators need only ensure PodDisruptionBudgets exist for stateful workloads; Karpenter handles cordon, drain, and replacement.
- Cluster type-specific NodePool naming (`management-workloads` vs `regional-workloads`) is resolved at bootstrap time via the `CLUSTER_TYPE` environment variable injected into the ECS task.
