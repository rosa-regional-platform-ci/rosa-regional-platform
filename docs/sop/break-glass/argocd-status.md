# ArgoCD Status

## Purpose

Verify that all ArgoCD applications are synced and healthy on a Regional or Management Cluster, and debug any that are not.

## Prerequisites

1. Follow the [general break-glass prerequisites](README.md).
2. Connect to the bastion:
   ```bash
   scripts/dev/bastion-connect.sh regional    # or: management
   ```

## ArgoCD UI

To access the ArgoCD UI, port-forward from your laptop:

```bash
scripts/dev/bastion-port-forward.sh argocd regional    # or: management
```

The script will print the admin password and the local URL to access the UI.

## Check Application Sync Status

From the bastion, check the status and reconciled revision of all ArgoCD applications:

```bash
kubectl get applications -n argocd -o json \
  | jq -r '.items[] | [.metadata.name, .status.sync.status, .status.health.status, (.status.sync.revision // "-"), .status.reconciledAt] | @tsv' \
  | column -t -N APP,SYNC,HEALTH,REVISION,RECONCILED
```

All applications should show `Synced` and `Healthy`, the REVISION column should match the expected Git commit, and RECONCILED should be recent.

If `targetRevision` is a branch name (e.g. `main`), the reconciled revision should match the latest commit on that branch. A mismatch means ArgoCD has not yet picked up the most recent changes — see the debugging steps below to investigate why.

## Debugging Out-of-Sync Applications

Set the application name for the commands below:

```bash
APP_NAME=<app-name>
```

### 1. Identify the problem

Get details on the out-of-sync application:

```bash
kubectl get application $APP_NAME -n argocd -o json \
  | jq '{sync: .status.sync.status, conditions: .status.conditions}'
```

### 2. Check sync operation details

View the most recent sync result, including any errors:

```bash
kubectl get application $APP_NAME -n argocd \
  -o jsonpath='{.status.operationState}' | jq .
```

### 3. Check application resource diffs

See which resources are out of sync and what the diff is:

```bash
kubectl get application $APP_NAME -n argocd \
  -o jsonpath='{.status.resources[?(@.status!="Synced")]}' | jq .
```

### 4. Check ArgoCD controller logs

The application controller reconciles desired state with the cluster. Check here if apps are stuck syncing, not reconciling, or failing to apply resources:

```bash
kubectl logs -n argocd -l app.kubernetes.io/component=application-controller --tail=100
```

Follow logs in real-time while investigating:

```bash
kubectl logs -n argocd -l app.kubernetes.io/component=application-controller -f
```

### 5. Check ArgoCD repo-server logs

The repo-server clones Git repos and renders manifests (Helm, Kustomize). Check here if apps fail to fetch sources, render templates, or show revision mismatches:

```bash
kubectl logs -n argocd -l app.kubernetes.io/component=repo-server --tail=100
```

### 6. Check the target resource directly

If a specific resource is failing to apply, inspect it in the target namespace:

```bash
kubectl describe <resource-kind> <resource-name> -n <namespace>
kubectl get events -n <namespace> --sort-by='.lastTimestamp'
```

### 7. Check ArgoCD server logs

For API or UI-related issues:

```bash
kubectl logs -n argocd -l app.kubernetes.io/component=server --tail=100
```
