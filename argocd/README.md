# ROSA Regional Platform - ArgoCD Configuration

## Overview

Each cluster's ArgoCD is configured to use the ApplicationSet at `argocd/config/applicationset/base-applicationset.yaml` as its entrypoint. This ApplicationSet can be configured in two ways:

1. **Live Config**: Uses Helm charts from `argocd/config/<cluster_type>/` and `argocd/config/shared/` directly from the current git revision (main branch or your development branch passed during cluster provisioning)

2. **Pinned Commits**: Uses specific commit hashes that refer to a snapshotted point in time of the rosa-regional-platform repository's charts. This is used for progressive delivery where we "cut releases" by bundling applications.

## Repository Structure

```
argocd/
├── config/
│   ├── applicationset/
│   │   └── base-applicationset.yaml     # ApplicationSet entrypoint
│   ├── shared/                          # Shared charts (ArgoCD, etc.)
│   ├── management-cluster/              # MC-specific charts
│   └── regional-cluster/                # RC-specific charts
└── config.yaml                          # Source of truth for all region deployments

scripts/
└── render.py                            # Generates values, ApplicationSets, and terraform configs

deploy/                                  # Generated outputs (DO NOT EDIT)
└── {environment}/{region_deployment}/
    ├── argocd/
    │   ├── {cluster_type}-values.yaml
    │   └── {cluster_type}-manifests/
    │       └── applicationset.yaml
    └── terraform/
        ├── regional.json
        └── management/
            └── {management_id}.json
```

## Configuration Modes

### Live Config (Integration)

- **Integration environments** run off the dynamic state in the current git revision (main or development branch configured for the cluster's ArgoCD)
- **No commit pinning** - always uses latest changes
- **Fast iteration** - changes appear immediately

### Pinned Commits (Staging/Production)

- **"Cut releases"** by specifying commit hashes in `config.yaml`
- **Progressive delivery** - roll through staging region deployments, then production region deployments
- **Immutable deployments** - exact reproducible state

## config.yaml - Source of Truth

This file defines which region deployments (environment + name combinations) exist and how they're configured:

```yaml
region_deployments:
  - name: "eu-west-1"
    aws_region: "eu-west-1"
    account_id: "123456789"
    management_clusters:
      - id: "mc01"
        account_id: "987654321"
    # No config_revision = uses current git revision
    values:
      management-cluster:
        hypershift:
          replicas: 1

  - name: "eu-west-1"
    aws_region: "eu-west-1"
    account_id: "123456789"
    management_clusters:
      - id: "mc01"
        account_id: "987654321"
    config_revision: # Pinned commits for stability
      management-cluster: "826fa76d08fc2ce87c863196e52d5a4fa9259a82"
      regional-cluster: "826fa76d08fc2ce87c863196e52d5a4fa9259a82"
    values:
      management-cluster:
        hypershift:
          replicas: 3
```

## Workflow

1. **Development**: Work with integration region deployments using live config (current branch)
2. **Release**: When ready, pin staging region deployments to tested commit hash
3. **Production**: Roll pinned commits through production region deployments
4. **Generate configs**: Run `./scripts/render.py` after changes

## Adding New Helm Charts

Create Helm charts in the appropriate directory based on where they should be deployed:

```bash
# For charts shared by all clusters
argocd/config/shared/my-new-app/
├── Chart.yaml
├── values.yaml
└── templates/

# For management cluster specific charts
argocd/config/management-cluster/my-mc-app/
├── Chart.yaml
├── values.yaml
└── templates/

# For regional cluster specific charts
argocd/config/regional-cluster/my-rc-app/
├── Chart.yaml
├── values.yaml
└── templates/
```

The ApplicationSet will automatically discover and deploy new charts. Run `./scripts/render.py` to generate the required configuration files.

## How It Works

ArgoCD uses a **Matrix Generator** pattern combining a Git Generator (discovers Helm charts) with a Cluster Generator (reads cluster identity). Charts are sourced from either a pinned commit hash or the current git revision, while rendered values always come from the latest revision.

For the full architecture, alternatives considered, and implementation details, see [GitOps Cluster Configuration](../docs/design/gitops-cluster-configuration.md).
