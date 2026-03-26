# Cross-Component E2E Testing

Component repositories (e.g., `rosa-regional-platform-api`) can run the rosa-regional-platform e2e test suite against a full ephemeral environment with their PR-built image deployed.

## Overview

A reusable [step-registry workflow](https://github.com/openshift/release/tree/master/ci-operator/step-registry/rosa-regional-platform/ephemeral-e2e) in `openshift/release` handles everything:

1. **Image build** — ci-operator builds the component's Docker image from the PR source
2. **Image push** — The image is copied to `quay.io/rrp-dev-ci/` using `oc image mirror` from the OCP `cli` image (public, so EKS can pull it without credentials), tagged `ci-<PR>-<BUILD_ID>`
3. **Provision** — Ephemeral environment provisioned from `rosa-regional-platform` main, with the component's Helm chart image overridden to point at the PR image
4. **E2E tests** — `./ci/e2e-tests.sh` from rosa-regional-platform runs against the environment
5. **Teardown** — Ephemeral environment torn down (fire-and-forget)

Component repos do **not** need their own e2e tests — the test suite in this repo (`rosa-regional-platform`) is used.

## Workflow Steps

| Step | Image | Purpose |
|------|-------|---------|
| `rosa-regional-platform-image-push` | `cli` | Copies CI-built image to quay.io using `oc image mirror` |
| `rosa-regional-platform-provision` | `rosa-regional-platform-ci` | Clones this repo, applies Helm image override, provisions |
| `rosa-regional-platform-e2e` | `rosa-regional-platform-ci` | Clones this repo, runs `./ci/e2e-tests.sh` |
| `rosa-regional-platform-teardown` | `rosa-regional-platform-ci` | Clones this repo, runs teardown |

The `rosa-regional-platform-ci` image is built from `ci/Containerfile` and promoted to the CI registry on every merge to `main`.

## CI Credentials

| Secret | Purpose |
|--------|---------|
| `rosa-regional-platform-dev-ci-quay-push` | Robot account for pushing to `quay.io/rrp-dev-ci/` |
| `rosa-regional-platform-ephemeral-creds` | AWS credentials for provisioning, e2e, and teardown |

Managed in [Vault](https://vault.ci.openshift.org/ui/vault/secrets/kv/kv/list/selfservice/cluster-secrets-rosa-regional-platform-int/).

## Image Override Mechanism

The provision step overrides a component's image in the Helm chart using these env vars (set per-repo in the CI config):

| Variable | Default | Description |
|----------|---------|-------------|
| `ROSA_REGIONAL_COMPONENT_NAME` | `""` | Component name (e.g., `platform-api`). Empty = no override |
| `ROSA_REGIONAL_HELM_VALUES_FILE` | `argocd/config/regional-cluster/platform-api/values.yaml` | Helm values file path |
| `ROSA_REGIONAL_HELM_IMAGE_REPO_PATH` | `app.image.repository` | yq path to image repo |
| `ROSA_REGIONAL_HELM_IMAGE_TAG_PATH` | `app.image.tag` | yq path to image tag |

The image-push step writes the full image ref to `${SHARED_DIR}/component-image-override`. The provision step reads it and uses `yq` to update the values file before running `./ci/nightly.sh`.

## SOP: Onboarding a New Component Repository

### Prerequisites

- The component has a `Dockerfile` that ci-operator can build
- The component is deployable via a Helm chart in this repo (rosa-regional-platform)

### Step 1: Create quay.io repository

Create a **public** repository under `quay.io/rrp-dev-ci/` for the component. Grant the existing robot account (used by `rosa-regional-platform-dev-ci-quay-push`) push access.

### Step 2: Add CI config in openshift/release

Edit `ci-operator/config/openshift-online/<repo>/<org>-<repo>-<branch>.yaml`.

Ensure a `releases` section exists (needed for the `cli` image used by the image-push step):

```yaml
releases:
  latest:
    release:
      channel: stable
      version: "4.21"
```

Add the test definition:

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
      ROSA_REGIONAL_QUAY_DEST_REPO: "quay.io/rrp-dev-ci/<component>"
    workflow: rosa-regional-platform-ephemeral-e2e
```

Where:
- `<pipeline-image-name>` — the `to` field from `images` (used as dependency name)
- `<component-name>` — name used in the Helm chart (e.g., `platform-api`)
- `quay.io/rrp-dev-ci/<component>` — public quay.io repo from step 1

Override Helm values paths if they differ from the defaults:

```yaml
    env:
      ROSA_REGIONAL_HELM_VALUES_FILE: "argocd/config/regional-cluster/my-component/values.yaml"
      ROSA_REGIONAL_HELM_IMAGE_REPO_PATH: "image.repo"
      ROSA_REGIONAL_HELM_IMAGE_TAG_PATH: "image.tag"
```

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
releases:
  latest:
    release:
      channel: stable
      version: "4.21"
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
      ROSA_REGIONAL_QUAY_DEST_REPO: quay.io/rrp-dev-ci/rosa-regional-platform-api
    workflow: rosa-regional-platform-ephemeral-e2e
```

## Troubleshooting

- **Image push fails**: Check quay.io repo exists, is public, and robot account has push access. The step uses `oc image mirror` from the `cli` image. Ensure the CI config has a `releases:` section so the `cli` image is available.
- **Provision fails**: Verify the `rosa-regional-platform-ci` promoted image exists (promotion PR merged + successful postsubmit). Check Helm values file path and yq paths match the chart.
- **E2e tests fail**: Check `BASE_URL` resolution — it comes from terraform outputs or credentials. See [Accessing Live Job Logs](README.md#accessing-live-job-logs) for debugging.
