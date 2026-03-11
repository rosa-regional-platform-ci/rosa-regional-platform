# HyperFleet API Chart - ArgoCD Application Wrapper

This Helm chart creates an ArgoCD Application resource that deploys the HyperFleet API Helm chart from an external Git repository.

## Purpose

This chart is a wrapper that allows the ArgoCD ApplicationSet to manage an Application pointing to an external Helm chart repository. Instead of directly deploying Kubernetes resources, this chart creates an ArgoCD Application manifest that references the upstream HyperFleet API charts.

## Architecture

```
ApplicationSet (base-applicationset.yaml)
  └─> hyperfleet-api-chart (this chart)
      └─> ArgoCD Application Resource
          └─> External HyperFleet API Helm Chart
              └─> Kubernetes Resources
```

## Sync Waves

hyperfleet-api-chart (syncWave: "-1"):
- Deploys first in wave -1
- Has CreateNamespace=true to create the hyperfleet-system namespace

hyperfleet-adapter1-chart (syncWave: "1"):
- Deploys after in wave 1
- Has CreateNamespace=false (namespace already exists)

hyperfleet-sentinel1-chart (syncWave: "1"):
- Deploys after in wave 1
- Has CreateNamespace=false (namespace already exists)


## Source Repository

The external HyperFleet API Helm chart is located at:
https://github.com/openshift-hyperfleet/hyperfleet-api/tree/main/charts
