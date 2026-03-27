# Thanos Metrics Infrastructure

**Last Updated**: 2026-03-26

## Summary

Thanos is deployed on regional clusters to ingest metrics from management clusters and store them
long-term in S3. The operator is consumed via an app-of-apps pattern — a slim wrapper chart renders
platform-specific resources and delegates operator installation to the upstream
`thanos-community/thanos-operator` chart at a pinned commit. The operator image uses the Red Hat RHOBS
Konflux build (UBI9, Clair/ClamAV/Snyk/Coverity) to meet FedRAMP image requirements.

## Context

**Problem**: Regional clusters need to collect metrics from multiple management clusters across AWS
accounts and retain them durably for compliance and operational visibility. The initial implementation
maintained the operator CRDs, Deployment, and RBAC locally — these drifted silently from upstream,
causing ArgoCD ServerSideApply failures when field names changed.

**Constraints**:

- FIPS-compliant AWS endpoints (FedRAMP)
- EKS Pod Identity for IAM auth — no static credentials
- KMS encryption at rest
- UBI9 base images with automated security scanning (Clair, ClamAV, Snyk)
- Minimize locally-maintained operator code

**Assumptions**: Management clusters send metrics via Prometheus `remote_write`. EKS Auto Mode remains
the compute strategy. Raw retention is 90d; downsampled retention is 180d (5m) and 365d (1h).

## Decision

Use an **app-of-apps wrapper** chart that renders only platform-specific resources (Thanos CRs, S3
secret, Pod Identity SA, ALB TGB) plus an ArgoCD `Application` (sync wave -1) that pulls the upstream
chart. Upgrade the upstream by updating one commit hash. Use the RHOBS image for FedRAMP compliance.

## Alternatives

| Option                                   | Rejected because                                                                  |
| ---------------------------------------- | --------------------------------------------------------------------------------- |
| Self-maintained CRDs (previous approach) | 5 CRD files (~38k lines) drifted silently; schema errors only caught at sync time |
| Bitnami Helm chart                       | No operator reconciliation; no FedRAMP-compliant image                            |
| Direct manifests                         | Highest maintenance burden; no automatic drift recovery                           |

## Consequences

**Positive**

- CRDs, Deployment, and RBAC are no longer maintained here — upgrading = one commit hash change
- RHOBS UBI9 image meets FedRAMP base image and scanning requirements
- S3/KMS/IAM values flow automatically from Terraform outputs → ECS bootstrap → ArgoCD cluster secret
- `SkipDryRunOnMissingResource=true` prevents sync failures during initial deploy before CRDs exist

**Negative**

- Initial deploy needs one ArgoCD self-healing retry (CRDs install in cycle 1, CRs apply in cycle 2)
- Upstream chart commit must be manually bumped to consume upstream fixes
- RHOBS image tags are commit hashes, not semantic versions

## Security

- FIPS S3 endpoint auto-selected for US regions; standard endpoint for non-US — no manual flag needed
- SSE-KMS encryption for all S3 writes
- EKS Pod Identity — no static credentials anywhere
- Least-privilege IAM role; one Pod Identity association per operator-managed service account

## Implementation

### How the Two Upstream Repos Are Used

```
thanos-community/thanos-operator  →  Helm chart pulled by ArgoCD at sync time
                                      (CRDs, operator Deployment, RBAC)
rhobs/rhobs-konflux-thanos-operator → Container image injected as override
                                      (same code, UBI9 base, Konflux scanning)
```

### ArgoCD Apps

Two ArgoCD applications are deployed to the regional cluster for Thanos:

| App (`argocd/config/regional-cluster/`) | Purpose                                                                     |
| --------------------------------------- | --------------------------------------------------------------------------- |
| `thanos-operator/`                      | Installs the Thanos operator (CRDs, Deployment, RBAC) via OCI Helm subchart |
| `thanos/`                               | Installs all platform-specific Thanos resources (CRs, secret, SA, TGB)      |

The `thanos-operator` chart is a thin wrapper with a single subchart dependency pulled from
`oci://quay.io/bsmit/rhobs-thanos-operator-chart`. The `thanos` chart also contains an ArgoCD
`Application` (sync wave -1) that can pull the operator from the upstream GitHub repo directly —
these two delivery mechanisms target the same operator and the active one should be selected based
on environment needs.

### Templates in `thanos/`

All templates are platform-specific resources not provided by either upstream repo:

| Template                  | Renders                        | Why here                                           |
| ------------------------- | ------------------------------ | -------------------------------------------------- |
| `application.yaml`        | ArgoCD `Application`           | App-of-apps glue; pulls upstream chart from GitHub |
| `receiver.yaml`           | `ThanosReceive` CR             | Platform config (replicas, storage, region labels) |
| `query.yaml`              | `ThanosQuery` CR               | Platform config (replicas, frontend)               |
| `store.yaml`              | `ThanosStore` CR               | Platform config (replicas, storage)                |
| `compact.yaml`            | `ThanosCompact` CR             | Platform config (retention, storage)               |
| `objstore-secret.yaml`    | `Secret` (`objstore.yml`)      | S3/KMS config from Terraform                       |
| `serviceaccount.yaml`     | `ServiceAccount`               | Pod Identity annotation — AWS-specific             |
| `targetgroupbinding.yaml` | `TargetGroupBinding`           | ALB wiring — AWS-specific                          |
| `_helpers.tpl`            | Shared label/annotation macros | `SkipDryRunOnMissingResource`, Helm release labels |

### Components

| Component              | Purpose                                        | Replicas |
| ---------------------- | ---------------------------------------------- | -------- |
| ThanosReceive Router   | Distributes incoming `remote_write` requests   | 1        |
| ThanosReceive Ingester | Stores metrics locally, ships 2h blocks to S3  | 1        |
| ThanosQuery            | Queries Receiver (live) and Store (historical) | 2        |
| ThanosQuery Frontend   | Caches and splits queries                      | 1        |
| ThanosStore            | Serves historical blocks from S3               | 2        |
| ThanosCompact          | Compacts and downsamples S3 blocks             | 1        |

### Terraform Resources (`terraform/modules/thanos-infrastructure/`)

- `aws_s3_bucket` — `${cluster_id}-thanos-metrics`, versioning + SSE-KMS + lifecycle policies
- `aws_kms_key` — dedicated key for Thanos S3 encryption
- `aws_iam_role` — least-privilege S3/KMS access; outputs wired to ECS bootstrap automatically
- `aws_eks_pod_identity_association` — one per operator-managed service account

### Key Pinned Values

| Setting               | Value                                                                     |
| --------------------- | ------------------------------------------------------------------------- |
| Upstream chart commit | `4c1d812c9fd88127087de406e7b569da9b9186fa`                                |
| RHOBS image tag       | `f83fea08f2a9167647cd8a9fd72f682c638c3cbb`                                |
| RHOBS image digest    | `sha256:c4512873aecd1c8ca8c83d6ddad8fa9e55d4c0924cf9453d97280845d7934830` |
| StorageClass          | `gp3` (shared chart, `ebs.csi.eks.amazonaws.com`, `WaitForFirstConsumer`) |

## Related

- [thanos-community/thanos-operator](https://github.com/thanos-community/thanos-operator)
- [rhobs/rhobs-konflux-thanos-operator](https://github.com/rhobs/rhobs-konflux-thanos-operator)
- [Thanos Documentation](https://thanos.io/tip/thanos/getting-started.md/)
- [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)
- [ArgoCD App of Apps Pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/)
