# ci/ephemeral-provider

Package for provisioning and tearing down ephemeral CI environments for ROSA Regional Platform.

## Usage

```bash
# Requires uv (https://docs.astral.sh/uv/)

# Provision
BUILD_ID=abc123 ./ci/ephemeral-provider/main.py --repo owner/repo --branch my-feature --creds-dir /path/to/credentials

# Teardown (same BUILD_ID)
BUILD_ID=abc123 ./ci/ephemeral-provider/main.py --teardown --repo owner/repo --branch my-feature --creds-dir /path/to/credentials
```

## Modules

| Module             | Description                                                        |
| ------------------ | ------------------------------------------------------------------ |
| `main.py`          | CLI entrypoint — parses args, runs provision or teardown           |
| `orchestrator.py`  | Top-level orchestration logic for provision and teardown workflows  |
| `aws.py`           | AWS credential management and session helpers                      |
| `git.py`           | Git operations for CI branch creation and rendered file management |
| `pipeline.py`      | CodeBuild pipeline monitoring (discovery, polling, status)         |
| `codebuild_logs.py`| CloudWatch log fetching and formatting for CodeBuild projects      |
