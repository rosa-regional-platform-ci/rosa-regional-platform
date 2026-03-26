# Cluster Monitoring Stack: Prometheus Operator via Helm Chart

**Last Updated Date**: 2026-03-26

## Summary

The ROSA Regional Platform deploys a `kube-prometheus-stack` Helm chart onto both Management Clusters (MC) and Regional Clusters (RC) to provide a self-contained Prometheus-based metrics collection layer. Alertmanager and Grafana are disabled; scraped metrics are forwarded externally to RHOBS (Red Hat Observability Service).

## Context

Each cluster (MC and RC) requires local metrics collection for platform components. The initial approach manually bundled upstream CRDs (PodMonitor, PrometheusRule, ServiceMonitor, Route) inside the HyperShift Helm chart. This created maintenance overhead and version drift risk as the CRDs are owned and versioned by the Prometheus Operator project.

- **Problem Statement**: Prometheus Operator CRDs were manually copied into `argocd/config/management-cluster/hypershift/crds/`, coupling their lifecycle to the HyperShift chart and requiring manual updates.
- **Constraints**: Clusters are fully private (no internet egress for scraping); HA is required across AZs; persistent storage must survive pod restarts; Alertmanager and Grafana are managed centrally in the RC rather than per-cluster.
- **Assumptions**: EBS gp3 storage is available in all target regions; metrics consumers (RHOBS) pull or receive forwarded metrics out-of-band from this stack.

## Alternatives Considered

1. **Manual CRD management in HyperShift chart**: Continue bundling CRD YAML files directly in `argocd/config/management-cluster/hypershift/crds/`. Simple but creates version drift risk and couples CRD upgrades to HyperShift chart releases.
2. **kube-prometheus-stack as a standalone Helm chart (chosen)**: Deploy the Prometheus Operator via its upstream Helm chart as a separate ArgoCD-managed application, letting the operator own its own CRDs.
3. **Managed Prometheus (e.g. AWS Managed Prometheus)**: Offload collection to a managed service. Rejected due to cost and the need for in-cluster ServiceMonitor/PodMonitor support for platform components.

## Design Rationale

- **Justification**: The Prometheus Operator Helm chart (`kube-prometheus-stack`) installs and manages its own CRDs as part of the chart lifecycle, eliminating the need for manual CRD copies. Deploying it as a first-class ArgoCD application means upgrades follow the same GitOps flow as all other cluster applications.
- **Evidence**: The removed CRD files (`00-podmonitors`, `00-prometheusrules`, `00-routes`, `00-servicemonitors`) were static copies of upstream resources with no automated update path. The chart-managed approach ties CRD versions to a specific, pinned chart version (`kube-prometheus-stack` 72.6.2).
- **Comparison**: Manual CRD management required separate PRs to update CRDs alongside operator version bumps. The chart approach keeps CRDs and operator in sync automatically within the same chart version pin.

## Consequences

### Positive

- CRD versions are automatically consistent with the operator version — no manual synchronization required.
- Monitoring stack upgrades follow the same GitOps flow as other cluster applications (chart version bump in `Chart.yaml`).
- Both MC and RC have symmetric monitoring configurations, simplifying operations.
- Prometheus is HA across two AZs via topology spread constraints and two replicas.
- Persistent 100Gi EBS volumes survive pod restarts and node replacements without data loss.

### Negative

- Chart upgrades that include CRD changes require careful sequencing (ArgoCD does not automatically upgrade CRDs on Helm chart updates by default — the `crds.enabled: true` value in `values.yaml` handles initial installation but CRD upgrades may need manual intervention).
- Running two Prometheus replicas with 100Gi persistent volumes each per cluster increases EBS costs.

## Cross-Cutting Concerns

### Reliability

- **Scalability**: Each cluster runs two Prometheus replicas. As the number of clusters grows, monitoring capacity scales per-cluster independently.
- **Observability**: Prometheus instances scrape all namespaces via namespace-wide `serviceMonitorSelector: {}` and `serviceMonitorNamespaceSelector: {}`, ensuring no service monitors are missed. Metrics are retained for 14 days locally (capped at 85 GB) before expiring.
- **Resiliency**: The `topologySpreadConstraints` configuration enforces `maxSkew: 1` across `topology.kubernetes.io/zone`, preventing both Prometheus replicas from landing in the same AZ. Storage uses `ReadWriteOnce` PVCs backed by EBS, providing durable persistence across pod restarts.

### Operability

- The stack is deployed via ArgoCD as a standard Helm chart application — no manual `kubectl` operations required to install or upgrade.
- Alertmanager and Grafana are explicitly disabled (`enabled: false`) to keep per-cluster resource footprint minimal and avoid duplicating dashboards and alert routing across every cluster. These components are managed centrally.
- The `storageclass` chart (at `argocd/config/shared/storageclass/`) is shared between MC and RC and ensures the gp3 StorageClass is available before the monitoring PVCs are created. This chart was refactored out of the HyperShift chart at the same time to make it reusable.
