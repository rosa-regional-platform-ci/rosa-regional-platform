# ci/ephemeral-provider

Python package for provisioning, resyncing, and tearing down ephemeral CI environments for ROSA Regional Platform.

For local development usage via Make targets, see [Provisioning a Development Environment](../../docs/development-environment.md).

## Direct Usage

```bash
# Requires uv (https://docs.astral.sh/uv/)

# Provision
BUILD_ID=abc123 ./ci/ephemeral-provider/main.py --repo owner/repo --branch my-feature --creds-dir /path/to/credentials

# Teardown (same BUILD_ID)
BUILD_ID=abc123 ./ci/ephemeral-provider/main.py --teardown --repo owner/repo --branch my-feature --creds-dir /path/to/credentials

# Resync (rebase CI branch onto latest source branch, same BUILD_ID)
BUILD_ID=abc123 ./ci/ephemeral-provider/main.py --resync --repo owner/repo --branch my-feature --creds-dir /path/to/credentials
```

## Overrides

Two mechanisms let you customize an ephemeral environment at provision time:

### `--override-dir`

Replaces the entire `config/ephemeral/` directory with a local directory of YAML files. Use this to swap the region, change cluster sizing, or provide a fully custom environment config. Re-applied on `--resync` so config changes are picked up alongside code changes.

```bash
./ci/ephemeral-provider/main.py --override-dir ./my-overrides/ ...
```

Also settable via `EPHEMERAL_OVERRIDE_DIR` env var.

### `--provision-override-file`

Deep-merges a YAML fragment into a specific file in the repo before the CI branch is committed. Useful for surgical changes like overriding a single Helm value without replacing the whole file. Only applied during provision (not resync).

```bash
./ci/ephemeral-provider/main.py \
  --provision-override-file argocd/config/regional-cluster/platform-api/values.yaml:override.yaml \
  ...
```

Can be specified multiple times. Format is `<target-path>:<override-file>` where target path is relative to the repo root. Merge rules:

- Dicts are merged recursively
- Lists of dicts are matched by `name` key (matched items are merged, unmatched are appended)
- Scalars and plain lists are replaced

## Modules

| Module              | Description                                                           |
| ------------------- | --------------------------------------------------------------------- |
| `main.py`           | CLI entrypoint — parses args, runs provision, teardown, or resync     |
| `orchestrator.py`   | Top-level orchestration logic for provision and teardown workflows    |
| `aws.py`            | AWS credential management and session helpers                         |
| `git.py`            | Git operations for CI branch creation, rendering, and resync (rebase) |
| `pipeline.py`       | CodeBuild pipeline monitoring (discovery, polling, status)            |
| `codebuild_logs.py` | CloudWatch log fetching and formatting for CodeBuild projects         |
| `yaml_utils.py`     | YAML deep-merge utilities for applying provision overrides            |
