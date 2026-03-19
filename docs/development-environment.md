# Provisioning a Development Environment

Ephemeral environments are short-lived, isolated stacks for developing and testing the ROSA Regional Platform. All commands run inside a container on your local machine (podman or docker) and interact with shared development AWS credentials (central, regional, management accounts).

Each environment gets a unique ID that prefixes all provisioned resources, keeping environments isolated from each other. The ephemeral provider creates a managed clone of your remote branch and uses it to drive provisioning and ArgoCD syncs. To push subsequent changes into a running environment, use [Resync](#resync).

## Provision

> ⚠️ _Ensure your changes are pushed to the remote branch before provisioning — the environment is built from the remote ref, not your local working tree._

```bash
# Interactive — fzf picker for remote and branch
make ephemeral-provision

# Explicit — skip the picker
make ephemeral-provision REPO=owner/repo BRANCH=my-feature REGION=us-east-1
```

On success the command prints the environment ID as well as guidance to interact with the environment.

To view and interact with provisioned environments at a later point in time, see [List Environments](#list-environments).

## List Environments

Lists environments you have provisioned from your local machine. State is cached in the `.ephemeral-envs` file in the repo root — you can clear it at any time by deleting the file.

To interact with a previously provisioned environment, list your environments and pass the ID to the relevant command (e.g. `make ephemeral-shell ID=<id>`).

```bash
make ephemeral-list
```

Example:

```
Ephemeral environments:

ID           REPO                                          BRANCH                    REGION       STATE                  CREATED              API_URL
------------ --------------------------------------------- ------------------------- ------------ ---------------------- -------------------- -------
6bd2d3d7     typeid/rosa-regional-platform                 ROSAENG-143               us-east-1    ready                  2026-03-19T10:14:23Z https://thfvcunmr3.execute-api.us-east-1.amazonaws.com/prod

To clear list: rm .ephemeral-envs
```

## Shell Access

Opens an interactive shell pre-configured with regional AWS credentials to interact directly with the API Gateway.

```bash
# Interactive — fzf picker for environment selection
make ephemeral-shell

# Explicit
make ephemeral-shell ID=6bd2d3d7
```

Example:

```
Fetching credentials from Vault (OIDC login)...
Credentials loaded (in-memory only).

ROSA Regional Platform shell

API Gateway: https://thfvcunmr3.execute-api.us-east-1.amazonaws.com/prod
Region:      us-east-1

Example commands:
  awscurl --service execute-api https://thfvcunmr3.execute-api.us-east-1.amazonaws.com/prod/v0/live

[root@df2f729c21c2 /]# awscurl --service execute-api https://thfvcunmr3.execute-api.us-east-1.amazonaws.com/prod/v0/live
{"status":"ok"}
```

## Run E2E Tests

Run the end-to-end test suite against one of your development environments:

```bash
# Interactive — fzf picker for environment selection
make ephemeral-e2e

# Explicit
make ephemeral-e2e ID=6bd2d3d7
```

## Resync

The ephemeral environment runs from an ephemeral-provider managed clone of your branch. If you push additional changes to your remote branch after provisioning (e.g. updating a Helm chart or Terraform module), the environment won't pick them up automatically — you need to resync so the cloned branch is updated and ArgoCD syncs the changes.

```bash
# Interactive — fzf picker for environment selection
make ephemeral-resync

# Explicit
make ephemeral-resync ID=6bd2d3d7
```

## Tear Down

Destroy an environment and all its resources:

```bash
# Interactive — fzf picker for environment selection
make ephemeral-teardown

# Explicit
make ephemeral-teardown ID=6bd2d3d7
```

## Further Reading

- [Milestone 2 slides](presentations/milestone-2/slides.md) -- ephemeral provider architecture and how environments are provisioned/torn down
- [ci/ephemeral-provider/README.md](../ci/ephemeral-provider/README.md) -- ephemeral provider internals
