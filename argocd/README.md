# ROSA Regional Platform - ArgoCD Configuration

## Overview

Each cluster's ArgoCD uses an **app-of-apps pattern** for deployment. A thin ApplicationSet (cluster generator) creates a single `app-of-apps` Application that deploys a Helm chart rendering all child Applications with sync-wave annotations for ordered deployment.

The system supports two configuration modes:

1. **Live Config**: Helm charts track the current git revision (integration environments)
2. **Pinned Commits**: Charts pinned to a specific commit hash (staging/production)

## Repository Structure

```text
argocd/
├── config/
│   ├── app-of-apps/                     # Parent chart — renders all child Applications
│   ├── shared/                          # Charts deployed to both RC and MC
│   ├── management-cluster/              # MC-specific charts
│   └── regional-cluster/                # RC-specific charts
└── README.md

config/                                  # Region deployment configuration
└── <env>/
    ├── defaults.yaml                    # Per-environment defaults
    └── <region>.yaml                    # Per-region values (git.revision for pinning)

deploy/                                  # Generated outputs (DO NOT EDIT)
└── {environment}/{region}/
    ├── argocd-values-{cluster_type}.yaml
    └── argocd-bootstrap-{cluster_type}/
        └── applicationset.yaml
```

## Configuration Modes

### Live Config (Integration)

- **Integration environments** run off the dynamic state in the current git revision (main or development branch configured for the cluster's ArgoCD)
- **No commit pinning** — always uses latest changes
- **Fast iteration** — changes appear immediately

### Pinned Commits (Staging/Production)

- **"Cut releases"** by setting `git.revision` to a commit hash in the region config
- **Progressive delivery** — roll through staging region deployments, then production region deployments
- **Immutable deployments** — exact reproducible state

See [Config Directory](../config/README.md) for the full configuration hierarchy and examples.

## Adding Applications

To add a new application, plumb a Terraform value, or configure secrets from AWS Secrets Manager, see [Adding an ArgoCD Application](../docs/adding-argocd-application.md).

## How It Works

ArgoCD uses an **app-of-apps pattern** where a thin ApplicationSet generates a single parent Application pointing to the `argocd/config/app-of-apps/` Helm chart. That chart renders child Application CRs with sync-wave annotations, ensuring ordered deployment (CRD operators before CRD consumers, infrastructure before platform workloads).

For the full architecture, alternatives considered, and implementation details, see [GitOps Cluster Configuration](../docs/design/gitops-cluster-configuration.md).

## Workflow

1. **Development**: Work with integration region deployments using live config (current branch)
2. **Release**: When ready, pin staging region deployments to tested commit hash
3. **Production**: Roll pinned commits through production region deployments
4. **Generate configs**: Run `make render` after changes
