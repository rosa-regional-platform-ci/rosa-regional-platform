# Thanos Metrics Infrastructure for Cross-Account Metrics Ingestion

**Last Updated Date**: 2026-03-25

## Summary

We implemented Thanos using the thanos-community operator to provide cross-account metrics ingestion with long-term storage in S3. This enables regional clusters to receive, store, query, and compact Prometheus metrics from management clusters while maintaining FedRAMP compliance through FIPS endpoints and KMS encryption.

## Context

- **Problem Statement**: The ROSA Regional Platform requires a centralized metrics collection system that can ingest metrics from multiple management clusters across AWS accounts. Metrics must be stored durably for compliance and operational visibility, with support for long-term retention and efficient querying.

- **Constraints**:
  - Must use FIPS-compliant AWS endpoints for FedRAMP compliance
  - Must integrate with EKS Pod Identity for IAM authentication (no static credentials)
  - Must work with EKS Auto Mode's dynamic node provisioning
  - Must support KMS encryption for data at rest
  - Should use Kubernetes-native management (operators/CRDs) for GitOps compatibility

- **Assumptions**:
  - Management clusters will send metrics via Prometheus remote_write protocol
  - Metrics retention of 90 days for raw data, longer for downsampled data
  - The thanos-community operator will reach stable releases (currently alpha)
  - EKS Auto Mode will remain the compute provisioning strategy

## Alternatives Considered

1. **Banzai Cloud thanos-operator**: A mature Kubernetes operator with established CRDs for managing Thanos components. Provides ObjectStore, Receiver, and Thanos CRDs for declarative management.

2. **thanos-community operator**: An actively developed community operator providing ThanosReceive, ThanosQuery, ThanosStore, ThanosCompact, and ThanosRuler CRDs. Currently in alpha but backed by the Thanos community.

3. **Bitnami Thanos Helm Chart**: A production-ready Helm chart that deploys Thanos components directly as Deployments and StatefulSets without an operator. Well-documented and actively maintained.

4. **Direct Thanos Manifests**: Manual creation of Kubernetes manifests (Deployments, StatefulSets, Services) for each Thanos component without any abstraction layer.

## Design Rationale

- **Justification**: The thanos-community operator was selected because it provides Kubernetes-native CRD management while being actively developed by the Thanos community. Unlike the Banzai Cloud operator (abandoned in 2021), it receives regular updates and bug fixes. Unlike direct manifests or Helm-only approaches, it provides reconciliation and self-healing capabilities.

- **Evidence**:
  - Banzai Cloud operator: Last release v0.3.7 in 2021, no commits in 3+ years
  - thanos-community operator: Regular commits, active GitHub issues/PRs, published container images
  - Community backing ensures long-term viability as Thanos evolves

- **Comparison**:
  - **vs Banzai Cloud**: Rejected due to abandonment; CRD schema was outdated and incompatible with newer Thanos features
  - **vs Bitnami Helm**: More operational overhead without operator reconciliation; no CRD-based management for GitOps
  - **vs Direct Manifests**: Higher maintenance burden; no automatic recovery from configuration drift

## Consequences

### Positive

- Kubernetes-native management via CRDs enables GitOps workflows with ArgoCD
- Operator handles service account creation, StatefulSet management, and component coordination
- Active community development means bugs are addressed and new features added
- CRD-based approach allows declarative configuration versioned in Git
- Automatic discovery between Thanos components (Query finds Stores/Receivers)

### Negative

- Alpha status means API may change, requiring manifest updates
- No stable release tags; must pin to commit-based image tags
- Operator creates its own service accounts, requiring additional Pod Identity associations in Terraform
- Less documentation compared to mature solutions like Bitnami
- Required additional CRDs (Prometheus Operator's ServiceMonitor/PrometheusRule) as dependencies

## Cross-Cutting Concerns

### Reliability

- **Scalability**: ThanosReceive supports multiple hashrings for horizontal scaling. ThanosQuery can scale replicas independently. ThanosStore shards data access across replicas.
- **Observability**: All Thanos components expose Prometheus metrics on port 10902. Query provides a web UI for ad-hoc queries. Components emit structured logs.
- **Resiliency**: S3 provides 11 9's durability for stored metrics. StatefulSets with PVCs ensure local data survives pod restarts. Replication factor configurable for ThanosReceive.

### Security

- FIPS-compliant S3 endpoint (`s3-fips.{region}.amazonaws.com`) for all object storage operations
- KMS encryption (SSE-KMS) for data at rest in S3
- EKS Pod Identity for IAM authentication (no static credentials)
- Network policies can restrict traffic to Thanos components
- Operator runs with minimal RBAC permissions; secrets access is read-only
- Container security context enforces `readOnlyRootFilesystem` and drops all capabilities

### Performance

- ThanosCompact downsamples data (5m and 1h resolutions) reducing query load for long-range queries
- ThanosStore caches block metadata in memory for faster queries
- gp3 EBS volumes provide consistent IOPS for local TSDB operations
- WaitForFirstConsumer storage binding ensures volumes are provisioned in the same AZ as pods

### Cost

- S3 Standard storage for metrics with lifecycle policies for automatic cleanup
- gp3 volumes (50Gi for Receiver, 20Gi for Store) provide cost-effective persistent storage
- Compaction reduces long-term storage costs through downsampling
- Single IAM role shared across all Thanos components minimizes IAM resource count

### Operability

- GitOps deployment via ArgoCD ApplicationSet
- Terraform manages infrastructure (S3, KMS, IAM, Pod Identity associations)
- Helm chart in repository allows local testing with `helm upgrade --install`
- StorageClass configured for EKS Auto Mode compatibility (`ebs.csi.eks.amazonaws.com`, `WaitForFirstConsumer`)
- Predictable service account naming enables Terraform-managed Pod Identity associations

## Implementation Details

### Components Deployed

| Component | Purpose | Replicas |
|-----------|---------|----------|
| ThanosReceive Router | Distributes incoming remote_write requests | 1 |
| ThanosReceive Ingester | Stores received metrics locally, uploads to S3 | 1 |
| ThanosQuery | Queries data from Store and Receiver | 2 |
| ThanosQuery Frontend | Caches and splits queries | 1 |
| ThanosStore | Serves historical data from S3 | 2 |
| ThanosCompact | Compacts and downsamples S3 data | 1 |

### Terraform Resources

- `aws_s3_bucket` with versioning, encryption, and lifecycle policies
- `aws_kms_key` for S3 SSE-KMS encryption
- `aws_iam_role` with S3 and KMS permissions
- `aws_eks_pod_identity_association` for each operator-created service account

### Key Configuration Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| StorageClass provisioner | `ebs.csi.eks.amazonaws.com` | EKS Auto Mode uses managed CSI driver |
| Volume binding mode | `WaitForFirstConsumer` | Allows scheduler to pick node before volume provisioning |
| S3 endpoint | `s3-fips.{region}.amazonaws.com` | FedRAMP compliance requirement |
| Operator image tag | `main-2025-01-15-e8a4b2c` | Pinned commit for stability until stable releases |

## Related Documentation

- [Thanos Documentation](https://thanos.io/tip/thanos/getting-started.md/)
- [thanos-community/thanos-operator](https://github.com/thanos-community/thanos-operator)
- [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)
- [AWS FIPS Endpoints](https://aws.amazon.com/compliance/fips/)
