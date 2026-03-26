# Thanos Metrics Infrastructure for Cross-Account Metrics Ingestion

**Last Updated Date**: 2026-03-26

## Summary

We deploy Thanos on regional clusters using an app-of-apps pattern: a slim wrapper Helm chart renders
platform-specific resources (Thanos CRs, Pod Identity ServiceAccount, objstore secret) and an ArgoCD
`Application` that pulls the upstream `thanos-community/thanos-operator` chart at a pinned commit. The
operator image is sourced from the Red Hat RHOBS Konflux build, providing a UBI9 base image with
automated security scanning (Clair, ClamAV, Snyk, Coverity).

## Context

- **Problem Statement**: The ROSA Regional Platform requires a centralized metrics collection system
  that can ingest metrics from multiple management clusters across AWS accounts. Metrics must be stored
  durably for compliance and operational visibility, with support for long-term retention and efficient
  querying. The initial implementation maintained the operator CRDs, Deployment, and RBAC locally in
  the repository, creating a maintenance burden as the upstream schema evolved and introducing silent
  drift when the upstream CRD definitions changed.

- **Constraints**:
  - Must use FIPS-compliant AWS endpoints for FedRAMP compliance
  - Must integrate with EKS Pod Identity for IAM authentication (no static credentials)
  - Must work with EKS Auto Mode's dynamic node provisioning
  - Must support KMS encryption for data at rest
  - Must use UBI9-based container images for FedRAMP compliance (no community Alpine/Debian bases)
  - Must use images with automated security scanning (Clair, ClamAV, Snyk, or equivalent)
  - Should use Kubernetes-native management (operators/CRDs) for GitOps compatibility
  - Should minimize operator-managed code in this repository to reduce maintenance burden

- **Assumptions**:
  - Management clusters will send metrics via Prometheus remote_write protocol
  - Metrics retention of 90 days for raw data, 180 days for 5m downsampled, 365 days for 1h downsampled
  - The thanos-community operator remains under active development
  - EKS Auto Mode will remain the compute provisioning strategy
  - ArgoCD's app-of-apps sync wave ordering is sufficient for CRD installation sequencing

## Alternatives Considered

1. **Self-maintained operator chart with local CRDs**: The previous approach — copy the upstream CRDs
   and operator Deployment/RBAC into this repository and maintain them alongside the Thanos component
   CRs. Provides full control but requires manual updates when the upstream schema changes and risks
   silent drift.

2. **App-of-apps wrapper referencing upstream chart (chosen)**: A slim wrapper chart that renders only
   platform-specific resources (Thanos CRs, Pod Identity ServiceAccount, TargetGroupBinding, objstore
   secret) and an ArgoCD `Application` (sync wave -1) that pulls the upstream
   `thanos-community/thanos-operator` Helm chart at a pinned commit. The operator Deployment, CRDs, and
   RBAC are delivered by the child Application, not maintained in this repository.

3. **Bitnami Thanos Helm Chart**: A production-ready chart that deploys Thanos components directly as
   Deployments and StatefulSets without an operator. Well-documented and actively maintained, but
   requires managing lifecycle operations (upgrades, scaling) manually rather than declaratively through
   CRDs.

4. **Direct Thanos Manifests**: Manual Kubernetes manifests for each Thanos component with no
   abstraction. Maximum control but highest maintenance burden and no automatic reconciliation.

## Design Rationale

- **Justification**: The app-of-apps wrapper eliminates the need to maintain the operator's CRDs,
  Deployment, and RBAC locally. When the upstream schema changes, only the pinned `targetRevision`
  commit hash needs updating — no manual CRD synchronization. The RHOBS Konflux build (`quay.io/
redhat-user-workloads/rhobs-mco-tenant/rhobs-thanos-operator-main/rhobs-thanos-operator-main`) is
  required over the community image because it uses a UBI9 base and goes through Red Hat's Konflux
  security pipeline (Clair, ClamAV, Snyk, Coverity), satisfying FedRAMP image requirements.

- **Evidence**:
  - Self-maintained CRDs (5 files, ~38,000 lines) drifted silently from the upstream schema, causing
    ServerSideApply failures in ArgoCD when field names changed (e.g., `queryFrontendSpec` →
    `queryFrontend`, `tenantMatcherType` removed)
  - Community operator image uses a non-UBI base, disqualifying it for FedRAMP environments
  - RHOBS image (`f83fea08f2a9167647cd8a9fd72f682c638c3cbb`, digest
    `sha256:c4512873aecd1c8ca8c83d6ddad8fa9e55d4c0924cf9453d97280845d7934830`) is built from the same
    upstream source with automated scanning attestations
  - Upstream chart pinned at commit `4c1d812c9fd88127087de406e7b569da9b9186fa` for stability

- **Comparison**:
  - **vs Self-maintained CRDs**: Rejected because any upstream CRD schema change requires a manual
    update to this repository; errors are discovered only at sync time rather than during chart
    authoring
  - **vs Bitnami Helm**: Rejected because operator-based CRD management integrates better with GitOps
    (declarative reconciliation, automatic discovery between components); also does not provide a
    FedRAMP-compliant image
  - **vs Direct Manifests**: Rejected due to highest maintenance burden and no automatic recovery from
    configuration drift

## Consequences

### Positive

- Kubernetes-native management via CRDs enables GitOps workflows with ArgoCD
- Operator CRDs, Deployment, and RBAC are no longer maintained in this repository; upstream changes
  are consumed by updating a single commit hash in `application.yaml`
- RHOBS UBI9 image satisfies FedRAMP base image and security scanning requirements
- ArgoCD sync wave ordering (`-1` on the child Application) ensures CRDs are installed before the
  parent Application attempts to apply Thanos CRs
- `SkipDryRunOnMissingResource=true` on all Thanos CRs prevents sync failures during initial deploy
  before CRDs exist
- Thanos infrastructure values (S3 bucket, KMS key ARN, IAM role ARN) flow automatically from
  Terraform `thanos-infrastructure` module outputs into the ECS bootstrap task, which writes them as
  ArgoCD cluster secret annotations — no manual wiring required

### Negative

- Two-level ArgoCD sync (parent app → child app for operator) means CRDs are installed one sync cycle
  before Thanos CRs become valid; initial deploy requires ArgoCD's self-healing retry
- Pinned upstream chart commit must be manually updated to consume upstream bug fixes or new features
- App-of-apps pattern adds an extra ArgoCD Application resource to monitor
- RHOBS image tags are commit hashes, not semantic versions, making upgrade reasoning less intuitive

## Cross-Cutting Concerns

### Reliability

- **Scalability**: ThanosReceive supports multiple hashrings for horizontal scaling. ThanosQuery scales
  replicas independently. ThanosStore shards block access across replicas.
- **Observability**: All Thanos components expose Prometheus metrics on port 10902. ThanosQuery
  provides a web UI for ad-hoc queries. The operator emits structured logs at configurable level.
- **Resiliency**: S3 provides 11 nines durability for stored metric blocks. StatefulSets with PVCs
  (gp3, WaitForFirstConsumer) ensure local TSDB data survives pod restarts. Replication factor is
  configurable on ThanosReceive for higher ingestion durability.

### Security

- FIPS-compliant S3 endpoint (`s3-fips.{region}.amazonaws.com`) for all object storage operations
- KMS encryption (SSE-KMS) for all data written to S3
- EKS Pod Identity for IAM authentication; no static credentials in secrets or environment variables
- Operator image sourced from RHOBS Konflux build with Clair, ClamAV, Snyk, and Coverity scan
  attestations; UBI9 base image
- Thanos infrastructure IAM role created by Terraform with least-privilege S3 and KMS permissions;
  associated to each operator-managed service account via Pod Identity associations
- `SkipDryRunOnMissingResource=true` is scoped only to Thanos CRs and does not affect other ArgoCD
  applications

### Performance

- ThanosCompact downsamples data at 5m and 1h resolutions, reducing query latency for long-range
  dashboards
- ThanosStore caches block metadata in memory for faster S3 object lookups
- gp3 EBS volumes (StorageClass `gp3`, provisioner `ebs.csi.eks.amazonaws.com`) provide consistent
  IOPS for local TSDB operations without the burst exhaustion risk of gp2
- `WaitForFirstConsumer` volume binding mode ensures volumes are provisioned in the same AZ as the
  pod, avoiding cross-AZ data transfer charges

### Cost

- S3 Standard storage for metric blocks with lifecycle policies enforced by ThanosCompact retention
  configuration (90d raw, 180d 5m, 365d 1h)
- gp3 volumes (50Gi Receiver, 20Gi Store, 50Gi Compactor) are sized for expected cardinality; resize
  without downtime via PVC expansion
- Single IAM role shared across all Thanos component service accounts minimizes IAM resource count
- Compaction reduces long-term storage footprint through downsampling

### Operability

- GitOps deployment via ArgoCD ApplicationSet; directory rename (`thanos-operator` → `thanos`) aligns
  the ApplicationSet `{{ .path.basename }}` destination namespace with the actual component namespace
- Terraform `thanos-infrastructure` module outputs (bucket name, KMS ARN, IAM role ARN) wired to ECS
  bootstrap module inputs; bootstrap task writes these as ArgoCD cluster secret annotations,
  eliminating manual configuration steps when provisioning a new regional cluster
- `helm template argocd/config/regional-cluster/thanos/` renders the full resource set for local
  inspection without a cluster
- Upstream chart version is controlled by a single commit hash in `templates/application.yaml`

## Implementation Details

### Helm Chart Structure

The `argocd/config/regional-cluster/thanos/` chart renders:

| Resource                   | Kind                              | Source                              |
| -------------------------- | --------------------------------- | ----------------------------------- |
| `thanos-operator-upstream` | ArgoCD Application (sync wave -1) | `templates/application.yaml`        |
| `thanos-objstore-config`   | Secret                            | `templates/objstore-secret.yaml`    |
| `thanos-operator`          | ServiceAccount                    | `templates/serviceaccount.yaml`     |
| `thanos-receive-tgb`       | TargetGroupBinding                | `templates/targetgroupbinding.yaml` |
| `thanos-receive`           | ThanosReceive CR                  | `templates/receiver.yaml`           |
| `thanos-query`             | ThanosQuery CR                    | `templates/query.yaml`              |
| `thanos-store`             | ThanosStore CR                    | `templates/store.yaml`              |
| `thanos-compact`           | ThanosCompact CR                  | `templates/compact.yaml`            |

The child Application (`thanos-operator-upstream`) pulls the upstream chart at commit
`4c1d812c9fd88127087de406e7b569da9b9186fa` and delivers: operator Deployment, ClusterRole,
ClusterRoleBinding, and all 5 CRDs (`ThanosReceive`, `ThanosStore`, `ThanosCompact`, `ThanosQuery`,
`ThanosRuler`).

### Components Deployed

| Component              | Purpose                                        | Replicas |
| ---------------------- | ---------------------------------------------- | -------- |
| ThanosReceive Router   | Distributes incoming remote_write requests     | 1        |
| ThanosReceive Ingester | Stores received metrics locally, uploads to S3 | 1        |
| ThanosQuery            | Queries data from Store and Receiver           | 2        |
| ThanosQuery Frontend   | Caches and splits queries                      | 1        |
| ThanosStore            | Serves historical data from S3                 | 2        |
| ThanosCompact          | Compacts and downsamples S3 data               | 1        |

### Terraform Resources

- `aws_s3_bucket` — `${cluster_id}-thanos-metrics` with versioning, SSE-KMS, and lifecycle policies
- `aws_kms_key` — dedicated key for Thanos S3 encryption
- `aws_iam_role` — least-privilege role with S3 and KMS permissions; outputs wired to ECS bootstrap
- `aws_eks_pod_identity_association` — one per operator-managed service account

### Key Configuration Decisions

| Decision                | Choice                                                    | Rationale                                                                |
| ----------------------- | --------------------------------------------------------- | ------------------------------------------------------------------------ |
| Operator image          | RHOBS Konflux build (`quay.io/redhat-user-workloads/...`) | UBI9 base, Clair/ClamAV/Snyk/Coverity scanning for FedRAMP               |
| Operator image tag      | `f83fea08f2a9167647cd8a9fd72f682c638c3cbb`                | Pinned commit; digest `sha256:c4512873...`                               |
| Upstream chart revision | `4c1d812c9fd88127087de406e7b569da9b9186fa`                | Pinned commit for reproducible deployments                               |
| StorageClass            | `gp3` (shared chart)                                      | EKS Auto Mode; consistent IOPS; eliminates custom StorageClass per chart |
| Volume binding mode     | `WaitForFirstConsumer`                                    | Scheduler picks node before volume provisioning                          |
| S3 endpoint             | `s3-fips.{region}.amazonaws.com`                          | FedRAMP FIPS compliance                                                  |
| ArgoCD sync wave        | `-1` on child Application                                 | Ensures CRDs exist before parent applies Thanos CRs                      |
| ArgoCD sync option      | `SkipDryRunOnMissingResource=true`                        | Prevents pre-validation failure for Thanos CRs before CRDs install       |

## Related Documentation

- [Thanos Documentation](https://thanos.io/tip/thanos/getting-started.md/)
- [thanos-community/thanos-operator](https://github.com/thanos-community/thanos-operator)
- [rhobs/rhobs-konflux-thanos-operator](https://github.com/rhobs/rhobs-konflux-thanos-operator)
- [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)
- [AWS FIPS Endpoints](https://aws.amazon.com/compliance/fips/)
- [ArgoCD App of Apps Pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/)
