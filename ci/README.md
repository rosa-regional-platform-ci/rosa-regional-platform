# CI

CI is managed through the [OpenShift CI](https://docs.ci.openshift.org/) system (Prow + ci-operator). The job configuration lives in [openshift/release](https://github.com/openshift/release/tree/master/ci-operator/config/openshift-online/rosa-regional-platform).

## Jobs

| Job                                                                                                                                                                                                                 | Schedule                  | Description                                                                                                                                             |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`check-docs`](https://prow.ci.openshift.org/job-history/gs/test-platform-results/pr-logs/directory/pull-ci-openshift-online-rosa-regional-platform-main-check-docs)                                                | Pre-submit                | Checks markdown formatting with [Prettier](https://prettier.io/)                                                                                        |
| [`terraform-validate`](https://prow.ci.openshift.org/job-history/gs/test-platform-results/pr-logs/directory/pull-ci-openshift-online-rosa-regional-platform-main-terraform-validate)                                | Pre-submit                | Runs `terraform validate` on all root modules                                                                                                           |
| [`helm-lint`](https://prow.ci.openshift.org/job-history/gs/test-platform-results/pr-logs/directory/pull-ci-openshift-online-rosa-regional-platform-main-helm-lint)                                                  | Pre-submit                | Lints Helm charts                                                                                                                                       |
| [`check-rendered-files`](https://prow.ci.openshift.org/job-history/gs/test-platform-results/pr-logs/directory/pull-ci-openshift-online-rosa-regional-platform-main-check-rendered-files)                            | Pre-submit                | Verifies rendered deploy files are up to date                                                                                                           |
| [`on-demand-e2e`](https://prow.ci.openshift.org/job-history/gs/test-platform-results/pr-logs/directory/pull-ci-openshift-online-rosa-regional-platform-main-on-demand-e2e)                                          | Pre-submit (manual)       | End-to-end: provisions ephemeral environment using PR rosa-regional-platform branch, runs tests, tears down. Trigger with `/test on-demand-e2e` on a PR |
| [`nightly-ephemeral`](https://prow.ci.openshift.org/job-history/gs/test-platform-results/logs/periodic-ci-openshift-online-rosa-regional-platform-main-nightly-ephemeral)                                           | Daily at 04:00 UTC        | End-to-end: provisions ephemeral environment using `main` rosa-regional-platform branch, runs tests, tears down                                         |
| [`nightly-integration`](https://prow.ci.openshift.org/job-history/gs/test-platform-results/logs/periodic-ci-openshift-online-rosa-regional-platform-main-nightly-integration)                                       | Daily at 04:00 UTC        | Runs e2e tests against a standing integration environment                                                                                               |
| [`ephemeral-resources-janitor`](https://prow.ci.openshift.org/job-history/gs/test-platform-results/logs/periodic-ci-openshift-online-rosa-regional-platform-main-ephemeral-resources-janitor)                       | Weekly (Sunday 12:00 UTC) | Purges leaked AWS resources across all ephemeral CI accounts using [aws-nuke](https://github.com/ekristen/aws-nuke)                                     |
| [`customer-account-ephemeral-ci-janitor`](https://prow.ci.openshift.org/job-history/gs/test-platform-results/logs/periodic-ci-openshift-online-rosa-regional-platform-main-customer-account-ephemeral-ci-janitor)   | Daily at 02:00 UTC        | Purges leaked HCP customer account resources (ephemeral CI) — mitigates missing HCP teardown flow                                                       |
| [`customer-account-ephemeral-dev-janitor`](https://prow.ci.openshift.org/job-history/gs/test-platform-results/logs/periodic-ci-openshift-online-rosa-regional-platform-main-customer-account-ephemeral-dev-janitor) | Daily at 02:00 UTC        | Purges leaked HCP customer account resources (ephemeral dev) — mitigates missing HCP teardown flow                                                      |
| `nightly-m6i` (planned)                                                                                                                                                                                             | Mon/Wed/Fri at 05:00 UTC  | Nightly ephemeral with `m6i.large` instance types — validates general-purpose Intel machines                                                            |
| `nightly-c6i` (planned)                                                                                                                                                                                             | Tue/Thu/Sat at 05:00 UTC  | Nightly ephemeral with `c6i.xlarge` instance types — validates compute-optimized Intel machines                                                         |

> **Note:** `nightly-m6i` and `nightly-c6i` are pending periodic job definitions in [openshift/release](https://github.com/openshift/release). Scripts and override files are ready in this repo.

## Load Testing (Planned)

Load testing scripts are implemented but not yet wired into the Prow workflow. The `rosa-regional-platform-load-test` step needs to be added to the `rosa-regional-platform-ephemeral-e2e` workflow in [openshift/release](https://github.com/openshift/release).

- **Entrypoint**: `ci/nightly-load-test.sh` (will run as a Prow step after e2e, before teardown)
- **Scripts**: `ci/load-test/scripts/platform-api-load.js` (API throughput), `ci/load-test/scripts/hcp-lifecycle-load.js` (concurrent HCP creation)
- **Results**: JSON summaries saved to `${ARTIFACT_DIR}/load-test-results/` (visible in Prow artifacts)
- **Baseline comparison**: `ci/load-test/compare-baseline.py` checks for regressions against an S3-stored baseline

### Machine-Type Overrides

The `ci/nightly-machine-type.sh` script provisions ephemeral environments with non-default EC2 instance types. Override files in `ci/nightly-overrides/machine-types/` are injected via `--provision-override-file`:

```bash
# Run locally with a specific machine type
MACHINE_TYPE_OVERRIDE=m6i-large.yaml ./ci/nightly-machine-type.sh
```

To add a new machine type, create a YAML file in `ci/nightly-overrides/machine-types/` with `regional_cluster.node_instance_types` and `management_cluster_defaults.node_instance_types` overrides.

## Cross-Component E2E Testing

Component repos (e.g., `rosa-regional-platform-api`) can run the e2e test suite against an ephemeral environment with their PR-built image deployed. See [Enabling Pre-Merge E2E for Component Repos](../docs/adding-component-pre-merge.md) for the full workflow, architecture, and SOP for onboarding new repos.

## Build Image

The CI image is built from [ci/Containerfile](ci/Containerfile) and includes all required tools:

| Tool      | Purpose                                       |
| --------- | --------------------------------------------- |
| Terraform | Infrastructure provisioning                   |
| Helm      | Kubernetes chart templating and linting       |
| AWS CLI   | AWS account and resource management           |
| Python/uv | Ephemeral provider and scripting              |
| Prettier  | Markdown formatting checks (`check-docs` job) |
| aws-nuke  | AWS resource cleanup (janitor job)            |
| yq        | YAML processing                               |

These tools are available in all CI job containers and can be used in scripts run by CI jobs.

## Ephemeral Environment

The [ci/ephemeral-provider/main.py](ci/ephemeral-provider/main.py) script manages ephemeral environments for CI testing. It supports three modes — provision, teardown (`--teardown`), and resync (`--resync`) — designed to run as separate CI steps with tests in between.

1. Creates a CI-owned git branch from the source repo/branch
2. Bootstraps the pipeline-provisioner pointing at the CI branch
3. Pushes rendered deploy files to trigger pipelines via GitOps
4. Waits for RC/MC pipelines to provision infrastructure
5. (Separate CI step) Runs the testing suite against the provisioned environment
6. Tears down infrastructure via GitOps (`delete: true` in config.yaml)
7. Destroys the pipeline-provisioner
8. CI branch is retained for post-run troubleshooting (delete manually via `git push ci --delete <branch>`)

### Running locally

See [Provisioning a Development Environment](../docs/development-environment.md) for the full guide on running ephemeral environments from your local machine via Make targets.

### Triggering the E2E Job Manually

1. Obtain an API token by visiting <https://oauth-openshift.apps.ci.l2s4.p1.openshiftapps.com/oauth/token/request>
2. Log in with `oc login`
3. Start the job:

```bash
# Trigger nightly-ephemeral
curl -X POST \
    -H "Authorization: Bearer $(oc whoami -t)" \
    'https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com/v1/executions/' \
    -d '{"job_name": "periodic-ci-openshift-online-rosa-regional-platform-main-nightly-ephemeral", "job_execution_type": "1"}'

# Trigger nightly-integration
curl -X POST \
    -H "Authorization: Bearer $(oc whoami -t)" \
    'https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com/v1/executions/' \
    -d '{"job_name": "periodic-ci-openshift-online-rosa-regional-platform-main-nightly-integration", "job_execution_type": "1"}'
```

4. Copy the `id` from the response and check the execution to get the Prow URL:

```bash
curl -X GET \
    -H "Authorization: Bearer $(oc whoami -t)" \
    'https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com/v1/executions/<id>'
```

Open the `job_url` from the response to watch the job in Prow.

## Accessing Live Job Logs

When a Prow job is running (e.g. `on-demand-e2e`), you can watch its logs in real time:

1. Open the Prow job page (e.g. from the PR status check link or the job history -- see jobs table above).

2. In the build log output, look for a line like:
   ```
   INFO[2026-03-10T11:41:49Z] Using namespace https://console.xxxxx.ci.openshift.org/k8s/cluster/projects/ci-op-XXXXXXXX
   ```
3. Click the namespace link to open the OpenShift console for the CI cluster where the job pods are running. From there you can inspect pod logs, events, and resources in real time.

> **Note:** Access to the namespace is restricted to the person who triggered the job (i.e. the PR author for pre-submit jobs). There is no configuration option to grant access to additional users.

## CI Credentials

The e2e jobs use credentials mounted at `/var/run/rosa-credentials/`. Credentials are managed in [Vault](https://vault.ci.openshift.org/ui/vault/secrets/kv/kv/list/selfservice/cluster-secrets-rosa-regional-platform-int/). Two credential secrets are used:

- `rosa-regional-platform-ephemeral-creds` — grants access to the AWS accounts used to spin up an ephemeral environment. Used by `nightly-ephemeral`, `on-demand-e2e`, `ephemeral-resources-janitor`, and `customer-account-ephemeral-ci-janitor`.
- `rosa-regional-platform-ephemeral-dev-creds` — grants access to the shared dev AWS accounts. Used by `customer-account-ephemeral-dev-janitor`.
- `rosa-regional-platform-integration-creds` — grants access to AWS credentials for testing against the API gateway in the regional integration account. Used by `nightly-integration`.

## Ephemeral Resources Janitor

The ephemeral tests create AWS resources across multiple accounts. Teardown relies on `terraform destroy`, which can fail and leak resources. The **ephemeral-resources-janitor** job is a weekly fallback that purges everything except resources we need to keep between tests using [aws-nuke](https://github.com/ekristen/aws-nuke).

The **customer-account janitor** jobs run daily to clean up HCP customer accounts, since there is currently no automated HCP teardown flow.

### Account selection

The janitor script accepts account names as arguments. If none are given, all accounts are purged.

```bash
# Purge all accounts
./ci/ephemeral-resources-janitor.sh

# Purge customer account only
./ci/ephemeral-resources-janitor.sh customer

# Purge specific accounts
./ci/ephemeral-resources-janitor.sh regional customer
```

Valid accounts: `regional`, `management`, `central`, `customer`.

### What is preserved

See `./ci/janitor/aws-nuke-config.yaml`. Preservation rules are organized as presets (`globals`, `ci`, `shared-dev`, `central`, `mc`, `customer`) composed per account.

### Running locally

```bash
# Dry-run (list only, no deletions)
./ci/janitor/purge-aws-account.sh

# Live run (actually delete resources)
./ci/janitor/purge-aws-account.sh --no-dry-run
```

The script uses whatever AWS credentials are active in your environment. The account must be in the allowlist in `ci/janitor/aws-nuke-config.yaml`.
