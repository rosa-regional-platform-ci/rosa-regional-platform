# Cross-Component E2E Testing

Component repositories (e.g., `rosa-regional-platform-api`) can run the rosa-regional-platform e2e test suite against a full ephemeral environment with their PR-built image deployed.

## Overview

A reusable [step-registry workflow](https://github.com/openshift/release/tree/master/ci-operator/step-registry/rosa-regional-platform/ephemeral-e2e) in `openshift/release` handles everything:

1. **Image build** — ci-operator builds the component's Docker image from the PR source
2. **Image push** — The image is copied to `quay.io/rrp-dev-ci/` using `oc image mirror` from the OCP `cli` image (public, so EKS can pull it without credentials), tagged `ci-<PR>-<BUILD_ID>`
3. **Provision** — Ephemeral environment provisioned from `rosa-regional-platform` main, with the component's Helm values deep-merged with an inline YAML override
4. **E2E tests** — `./ci/e2e-tests.sh` from rosa-regional-platform runs against the environment
5. **Teardown** — Ephemeral environment torn down (fire-and-forget)

Component repos do **not** need their own e2e tests — the test suite in this repo (`rosa-regional-platform`) is used.

## Workflow Steps

| Step | Image | Purpose |
|------|-------|---------|
| `rosa-regional-platform-image-push` | `ocp/4.21:cli` | Copies CI-built image to quay.io using `oc image mirror` |
| `rosa-regional-platform-provision` | `rosa-regional-platform-ci` | Calls ephemeral provider with YAML overrides, provisions environment |
| `rosa-regional-platform-e2e` | `rosa-regional-platform-ci` | Clones this repo, runs `./ci/e2e-tests.sh` |
| `rosa-regional-platform-teardown` | `rosa-regional-platform-ci` | Clones this repo, runs teardown |

The `rosa-regional-platform-ci` image is built from `ci/Containerfile` and promoted to the CI registry on every merge to `main`.

## CI Credentials

| Secret | Purpose |
|--------|---------|
| `rosa-regional-platform-dev-ci-quay-push` | Robot account for pushing to `quay.io/rrp-dev-ci/` |
| `rosa-regional-platform-ephemeral-creds` | AWS credentials for provisioning, e2e, and teardown |

Managed in [Vault](https://vault.ci.openshift.org/ui/vault/secrets/kv/kv/list/selfservice/cluster-secrets-rosa-regional-platform-int/).

## Override Mechanism

The provision step deep-merges a YAML fragment into a target file in the rosa-regional-platform repo before the ephemeral provider commits and pushes the CI branch. This is used to inject PR-built component images into Helm values files.

The override is configured via env vars in the CI config:

| Variable | Description |
|----------|-------------|
| `ROSA_REGIONAL_COMPONENT_NAME` | Component name for logging (e.g., `platform-api`). |
| `ROSA_REGIONAL_HELM_VALUES_FILE` | Path to the target file in this repo (e.g., `argocd/config/regional-cluster/platform-api/values.yaml`). |
| `ROSA_REGIONAL_HELM_OVERRIDE_YAML` | Inline YAML fragment to deep-merge into the target file. Use `IMAGE_REPO` and `IMAGE_TAG` as placeholders — they are replaced with the actual image reference from the image-push step. |
| `ROSA_REGIONAL_QUAY_DEST_REPO` | Public quay.io repository for the CI-built image. |

The deep merge works as follows:
- **Dicts** are merged recursively (override wins on conflicts).
- **Lists of dicts** are matched by `name` key — a matching item is merged, unmatched items are appended.
- **All other values** (scalars, lists of non-dicts) are replaced by the override.

### Image override example

For a values file with this structure:

```yaml
platformApi:
  app:
    image:
      repository: quay.io/rrp/platform-api
      tag: latest
```

The inline override YAML would be:

```yaml
ROSA_REGIONAL_HELM_OVERRIDE_YAML: |
  platformApi:
    app:
      image:
        repository: IMAGE_REPO
        tag: IMAGE_TAG
```

`IMAGE_REPO` and `IMAGE_TAG` are replaced at runtime with the actual image pushed by the image-push step.

### Chart version override example

For overriding a Helm chart dependency version in `Chart.yaml`:

```yaml
ROSA_REGIONAL_HELM_VALUES_FILE: argocd/config/management-cluster/cert-manager/Chart.yaml
ROSA_REGIONAL_HELM_OVERRIDE_YAML: |
  dependencies:
    - name: cert-manager
      version: v1.20.0
```

The `name: cert-manager` entry is matched against the existing dependencies list, and only the `version` field is updated. No placeholders needed since this isn't an image override.

## SOP: Onboarding a New Component Repository

### Prerequisites

- The component has a `Dockerfile` that ci-operator can build
- The component is deployable via a Helm chart in this repo (rosa-regional-platform)

### Step 1: Create quay.io repository

Create a **public** repository under `quay.io/rrp-dev-ci/` for the component. Grant the existing robot account (used by `rosa-regional-platform-dev-ci-quay-push`) push access.

### Step 2: Add CI config in openshift/release

Edit `ci-operator/config/openshift-online/<repo>/<org>-<repo>-<branch>.yaml`:

```yaml
images:
- dockerfile_path: Dockerfile
  to: <pipeline-image-name>

tests:
# ... existing tests ...
- always_run: false
  as: rosa-regionality-compatibility-e2e
  steps:
    dependencies:
      CI_COMPONENT_IMAGE: <pipeline-image-name>
    env:
      ROSA_REGIONAL_COMPONENT_NAME: "<component-name>"
      ROSA_REGIONAL_HELM_OVERRIDE_YAML: |
        <yaml-fragment-with-IMAGE_REPO-and-IMAGE_TAG-placeholders>
      ROSA_REGIONAL_HELM_VALUES_FILE: "argocd/config/regional-cluster/<component-name>/values.yaml"
      ROSA_REGIONAL_QUAY_DEST_REPO: "quay.io/rrp-dev-ci/<component>"
    workflow: rosa-regional-platform-ephemeral-e2e
```

Where:
- `<pipeline-image-name>` — the `to` field from your `images` section (used as the dependency name)
- `<component-name>` — the component's directory name under `argocd/config/regional-cluster/` in this repo (e.g., `platform-api`)
- `ROSA_REGIONAL_QUAY_DEST_REPO` — the public quay.io repo from step 1

#### How to write the override YAML

The `ROSA_REGIONAL_HELM_OVERRIDE_YAML` is a YAML fragment that gets deep-merged into the target file. To write it:

1. Open the component's values file in this repo (the path in `ROSA_REGIONAL_HELM_VALUES_FILE`).
2. Find the keys that control the container image — e.g., `platformApi.app.image.repository` and `platformApi.app.image.tag`.
3. Write just that YAML subtree, using `IMAGE_REPO` and `IMAGE_TAG` as placeholder values:

   ```yaml
   ROSA_REGIONAL_HELM_OVERRIDE_YAML: |
     platformApi:
       app:
         image:
           repository: IMAGE_REPO
           tag: IMAGE_TAG
   ```

Only include the keys you want to override — everything else in the values file is preserved.

### Step 3: Regenerate and submit

```bash
cd openshift/release
make update
make checkconfig
# Open PR
```

### Step 4: Trigger

On any PR in the component repo:

```
/test rosa-regionality-compatibility-e2e
```

### Example: rosa-regional-platform-api

```yaml
images:
- dockerfile_path: Dockerfile
  to: rosa-regional-platform-api
tests:
- always_run: false
  as: rosa-regionality-compatibility-e2e
  steps:
    dependencies:
      CI_COMPONENT_IMAGE: rosa-regional-platform-api
    env:
      ROSA_REGIONAL_COMPONENT_NAME: platform-api
      ROSA_REGIONAL_HELM_OVERRIDE_YAML: |
        platformApi:
          app:
            image:
              repository: IMAGE_REPO
              tag: IMAGE_TAG
      ROSA_REGIONAL_HELM_VALUES_FILE: argocd/config/regional-cluster/platform-api/values.yaml
      ROSA_REGIONAL_QUAY_DEST_REPO: quay.io/rrp-dev-ci/rosa-regional-platform-api
    workflow: rosa-regional-platform-ephemeral-e2e
```

## Troubleshooting

- **Image push fails**: Check quay.io repo exists, is public, and robot account has push access. The step uses `oc image mirror` from the OCP `cli` image (pulled directly from the `ocp/4.21` imagestream).
- **Provision fails**: Verify the `rosa-regional-platform-ci` promoted image exists (promotion PR merged + successful postsubmit). Check that `ROSA_REGIONAL_HELM_VALUES_FILE` points to an existing file in this repo and that the override YAML structure matches the target file.
- **E2e tests fail**: Check `BASE_URL` resolution — it comes from terraform outputs or credentials. See [Accessing Live Job Logs](README.md#accessing-live-job-logs) for debugging.
