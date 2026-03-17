# CI

CI is managed through the [OpenShift CI](https://docs.ci.openshift.org/) system (Prow + ci-operator). The job configuration lives in [openshift/release](https://github.com/openshift/release/tree/master/ci-operator/config/openshift-online/rosa-regional-platform).

## Jobs

| Job                                                                                                                                                                                           | Schedule                  | Description                                                                                                                                             |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`check-docs`](https://prow.ci.openshift.org/job-history/gs/test-platform-results/pr-logs/directory/pull-ci-openshift-online-rosa-regional-platform-main-check-docs)                          | Pre-submit                | Checks markdown formatting with [Prettier](https://prettier.io/)                                                                                        |
| [`terraform-validate`](https://prow.ci.openshift.org/job-history/gs/test-platform-results/pr-logs/directory/pull-ci-openshift-online-rosa-regional-platform-main-terraform-validate)          | Pre-submit                | Runs `terraform validate` on all root modules                                                                                                           |
| [`helm-lint`](https://prow.ci.openshift.org/job-history/gs/test-platform-results/pr-logs/directory/pull-ci-openshift-online-rosa-regional-platform-main-helm-lint)                            | Pre-submit                | Lints Helm charts                                                                                                                                       |
| [`check-rendered-files`](https://prow.ci.openshift.org/job-history/gs/test-platform-results/pr-logs/directory/pull-ci-openshift-online-rosa-regional-platform-main-check-rendered-files)      | Pre-submit                | Verifies rendered deploy files are up to date                                                                                                           |
| [`on-demand-e2e`](https://prow.ci.openshift.org/job-history/gs/test-platform-results/pr-logs/directory/pull-ci-openshift-online-rosa-regional-platform-main-on-demand-e2e)                    | Pre-submit (manual)       | End-to-end: provisions ephemeral environment using PR rosa-regional-platform branch, runs tests, tears down. Trigger with `/test on-demand-e2e` on a PR |
| [`nightly-ephemeral`](https://prow.ci.openshift.org/job-history/gs/test-platform-results/logs/periodic-ci-openshift-online-rosa-regional-platform-main-nightly-ephemeral)                     | Daily at 07:00 UTC        | End-to-end: provisions ephemeral environment using `main` rosa-regional-platform branch, runs tests, tears down                                         |
| [`nightly-integration`](https://prow.ci.openshift.org/job-history/gs/test-platform-results/logs/periodic-ci-openshift-online-rosa-regional-platform-main-nightly-integration)                 | Daily at 07:00 UTC        | Runs e2e tests against a standing integration environment                                                                                               |
| [`ephemeral-resources-janitor`](https://prow.ci.openshift.org/job-history/gs/test-platform-results/logs/periodic-ci-openshift-online-rosa-regional-platform-main-ephemeral-resources-janitor) | Weekly (Sunday 12:00 UTC) | Purges leaked AWS resources using [aws-nuke](https://github.com/ekristen/aws-nuke)                                                                      |

## Build Image

The CI image is built from [ci/Containerfile](ci/Containerfile) and includes all required tools (Terraform, Helm, AWS CLI, Python/uv, etc.).

## Pre-merge / Ephemeral Environment

The [ci/pre-merge.py](ci/pre-merge.py) script manages ephemeral environments for CI testing. It supports two modes — provision and teardown — designed to run as separate CI steps with tests in between.

1. Creates a CI-owned git branch from the source repo/branch
2. Bootstraps the pipeline-provisioner pointing at the CI branch
3. Pushes rendered deploy files to trigger pipelines via GitOps
4. Waits for RC/MC pipelines to provision infrastructure
5. (Separate CI step) Runs the testing suite against the provisioned environment
6. Tears down infrastructure via GitOps (`delete: true` in config.yaml)
7. Destroys the pipeline-provisioner
8. CI branch is retained for post-run troubleshooting (delete manually via `git push ci --delete <branch>`)

### Running locally

```bash
# Requires uv (https://docs.astral.sh/uv/)

# Provision
BUILD_ID=abc123 ./ci/pre-merge.py --repo owner/repo --branch my-feature --creds-dir /path/to/credentials

# Run tests (separate step, same BUILD_ID)

# Teardown
BUILD_ID=abc123 ./ci/pre-merge.py --teardown --repo owner/repo --branch my-feature --creds-dir /path/to/credentials
```

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

## Download CodeBuild Logs

`ci/download-codebuild-logs.py` downloads CloudWatch logs for all CodeBuild projects matching a CI prefix. It fetches every log stream (build run) per project and names files with timestamps (e.g. `ci-202982-regional-apply.20260306-075604.log`) for chronological ordering. ANSI color codes are stripped from the output.

```bash
# Download all logs for a CI run (requires uv)
./ci/download-codebuild-logs.py ci-202982

# Specify a region (default: us-east-1)
./ci/download-codebuild-logs.py ci-202982 --region eu-west-1
```

Logs are saved to `codebuild-logs-<ci-prefix>/`. The same download logic is used by `ephemerallib` to collect logs into Prow artifacts (with additional secret redaction).

## CI Credentials

The e2e jobs use credentials mounted at `/var/run/rosa-credentials/`. Credentials are managed in [Vault](https://vault.ci.openshift.org/ui/vault/secrets/kv/kv/list/selfservice/cluster-secrets-rosa-regional-platform-int/). Two credential secrets are used:

- `rosa-regional-platform-ephemeral-creds` — grants access to the AWS accounts used to spin up an ephemeral environment. Used by `nightly-ephemeral`, `on-demand-e2e`, and `ephemeral-resources-janitor`.
- `rosa-regional-platform-integration-creds` — grants access to AWS credentials for testing against the API gateway in the regional integration account. Used by `nightly-integration`.

## Ephemeral Resources Janitor

The ephemeral tests create AWS resources across multiple accounts. Teardown relies on `terraform destroy`, which can fail and leak resources. The **ephemeral-resources-janitor** job is a weekly fallback that purges everything except resources we need to keep between tests using [aws-nuke](https://github.com/ekristen/aws-nuke).

### What is preserved

See `./ci/aws-nuke-config.yaml`.

### Running locally

```bash
# Dry-run (list only, no deletions)
./ci/janitor/purge-aws-account.sh

# Live run (actually delete resources)
./ci/janitor/purge-aws-account.sh --no-dry-run
```

The script uses whatever AWS credentials are active in your environment. The account must be in the allowlist in `purge-aws-account.sh`.
