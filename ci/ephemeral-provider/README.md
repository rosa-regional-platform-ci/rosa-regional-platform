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

## Modules

| Module              | Description                                                           |
| ------------------- | --------------------------------------------------------------------- |
| `main.py`           | CLI entrypoint — parses args, runs provision, teardown, or resync     |
| `orchestrator.py`   | Top-level orchestration logic for provision and teardown workflows    |
| `aws.py`            | AWS credential management and session helpers                         |
| `git.py`            | Git operations for CI branch creation, rendering, and resync (rebase) |
| `pipeline.py`       | CodeBuild pipeline monitoring (discovery, polling, status)            |
| `codebuild_logs.py` | CloudWatch log fetching and formatting for CodeBuild projects         |
