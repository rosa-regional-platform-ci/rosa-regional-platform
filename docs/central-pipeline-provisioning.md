# Provision a New Central Pipeline

Set up a central pipeline that provisions Regional and Management Clusters with ArgoCD and Maestro connectivity.

---

## 1. Prerequisites

### Required tools

```bash
aws --version
terraform --version
python --version
jq --version
```

### 1.1 Required AWS accounts

Three accounts are needed:

- **Central** — hosts the CodePipeline infrastructure
- **Regional** — runs the Regional Cluster (EKS)
- **Management** — runs the Management Cluster (EKS)

The Regional and Management accounts must allow assume-role from Central (see 1.2).

### 1.2 Enable assume-role

Add the Central account to the `OrganizationAccountAccessRole` trust policy in both the Regional and Management accounts:

```bash
CENTRAL_ACCOUNT_ID="123456789012"
ROLE_NAME="OrganizationAccountAccessRole"

# Get current trust policy and add Central account
aws iam get-role --role-name $ROLE_NAME --query 'Role.AssumeRolePolicyDocument' --output json | \
  jq --arg account "arn:aws:iam::${CENTRAL_ACCOUNT_ID}:root" \
  '.Statement[0].Principal.AWS |= (if type == "array" then (. + [$account] | unique) else [., $account] | unique end)' \
  > /tmp/trust-policy-updated.json

aws iam update-assume-role-policy \
  --role-name $ROLE_NAME \
  --policy-document file:///tmp/trust-policy-updated.json

# Repeat for the Management account (switch credentials first)
```

## 2. Configure the Region

> **Skip this step** if reusing an existing environment/region configuration.

### 2.1 Store account IDs in SSM

Push the Regional and Management account IDs to SSM Parameter Store in the Central account. The default config uses the resolver URI `ssm:///infra/<environment>/<region>/account_id` to look up account IDs at runtime; the actual SSM parameter name stored in Parameter Store is `/infra/<environment>/<region>/account_id` (the `ssm://` prefix is stripped by the resolver).

```bash
ENV=my-env
REGION=us-east-1
RC_ACCOUNT_ID=123456789012    # Regional Cluster account
MC_ACCOUNT_ID=987654321098    # Management Cluster account

aws ssm put-parameter --name "/infra/${ENV}/${REGION}/account_id" \
  --value "$RC_ACCOUNT_ID" --type String
aws ssm put-parameter --name "/infra/${ENV}/${REGION}/mc01/account_id" \
  --value "$MC_ACCOUNT_ID" --type String
```

### 2.2 Add the environment to config.yaml

Edit `config.yaml`. See the header comments in that file for the full schema reference.

```yaml
environments:
  my-env:
    region_deployments:
      us-east-1:
        management_clusters:
          mc01: {}
```

This inherits all defaults (terraform_vars, values, SSM account_id patterns). Override only what differs — e.g. to enable the bastion:

```yaml
environments:
  my-env:
    terraform_vars:
      enable_bastion: true
    region_deployments:
      us-east-1:
        management_clusters:
          mc01: {}
```

### 2.3 Render and commit

```bash
./scripts/render.py
ls deploy/<environment>/<region>/    # verify argocd/ and terraform/ dirs exist

git add config.yaml deploy/
git commit -m "Add <environment>/<region> configuration"
git push origin <your-branch>
```

---

## 3. Bootstrap the Central Pipeline

Switch to your Central AWS profile and create the CodePipelines.

### 3.1 Run the bootstrap script

```bash
export AWS_PROFILE=<central-profile>

GITHUB_REPOSITORY=<org>/rosa-regional-platform \
GITHUB_BRANCH=<branch> \
TARGET_ENVIRONMENT=<environment> \
./scripts/bootstrap-central-account.sh
```

### 3.2 Accept the CodeStar connection

The bootstrap completes but the pipeline blocks until you authorize the GitHub connection:

1. Open the [AWS CodeStar Connections console](https://console.aws.amazon.com/codesuite/settings/connections) in the Central account
2. Find the **Pending** connection and click **Update pending connection**
3. Authorize with GitHub

Then retrigger the `pipeline-provisioner` pipeline in CodePipeline. Once it succeeds, `rc-pipe-*` and `mc-pipe-*` pipelines are created automatically.

### 3.3 Trigger pipelines via CLI (optional)

```bash
# List available pipelines
aws codepipeline list-pipelines \
  --query 'pipelines[*].[name,created,updated]' \
  --output table

# Trigger a specific pipeline (fetches latest commit)
aws codepipeline start-pipeline-execution --name rc-pipe-<hash>
```

### 3.4 Connect to the bastion (optional)

Requires `enable_bastion: true` in config. Switch to the Regional account:

```bash
export AWS_PROFILE=<regional-profile>

CLUSTER=$(aws ecs list-clusters | jq -r '.clusterArns[]' | cut -d'/' -f2 | grep bastion)
TASK_ID=$(aws ecs list-tasks --cluster $CLUSTER --query 'taskArns[0]' --output text | awk -F'/' '{print $NF}')
aws ecs execute-command --cluster $CLUSTER --task $TASK_ID --container bastion --interactive --command '/bin/bash'
```

### 3.5 Verify ArgoCD applications

From the bastion:

```bash
kubectl get applications -A
```

Expected output:

```
NAMESPACE   NAME                SYNC STATUS   HEALTH STATUS
argocd      argocd              Synced        Healthy
argocd      hyperfleet-system   Synced        Healthy
argocd      maestro-server      Synced        Healthy
argocd      platform-api        Synced        Healthy
argocd      root                Synced        Healthy
```

### 3.6 Verify the Platform API

From the Central account, extract the API Gateway endpoint from terraform output:

```bash
export AWS_PROFILE=<central-profile>
cd terraform/config/pipeline-regional-cluster/

terraform init -reconfigure \
  -backend-config="bucket=terraform-state-<CENTRAL_ACCOUNT_ID>" \
  -backend-config="key=regional-cluster/regional-<region>.tfstate" \
  -backend-config="region=<region>"

terraform output -raw api_test_command
# Then run the output command, e.g.:
# awscurl --service execute-api --region us-east-2 https://<id>.execute-api.<region>.amazonaws.com/prod/v0/live
```

> **Note:** `awscurl` must be run from the Regional account, which is the only account authorized by default.

## 4. Verify Maestro Connectivity

From the Regional account, verify IoT certificates are active:

```bash
export AWS_PROFILE=<regional-profile>

aws iot describe-endpoint --endpoint-type iot:Data-ATS
aws iot list-certificates | jq -r '.certificates[].status'
```

## 5. Verify Management Cluster

From the Central account:

```bash
export AWS_PROFILE=<central-profile>

# Check tfstate exists
aws s3 ls terraform-state-<CENTRAL_ACCOUNT_ID>/management-cluster/

# Connect to MC bastion (switch to Management account)
export AWS_PROFILE=<management-profile>

CLUSTER=$(aws ecs list-clusters | jq -r '.clusterArns[]' | cut -d'/' -f2 | grep bastion)
TASK_ID=$(aws ecs list-tasks --cluster $CLUSTER --query 'taskArns[0]' --output text | awk -F'/' '{print $NF}')
aws ecs execute-command --cluster $CLUSTER --task $TASK_ID --container bastion --interactive --command '/bin/bash'

# Verify MC applications
kubectl get applications -A
```

Expected output:

```
NAMESPACE   NAME            SYNC STATUS   HEALTH STATUS
argocd      argocd          Synced        Healthy
argocd      cert-manager    Synced        Healthy
argocd      hypershift      Synced        Healthy
argocd      maestro-agent   Synced        Healthy
argocd      root            Synced        Healthy
```

---

For manual post-pipeline steps, see [Consumer Registration & Verification](https://github.com/openshift-online/rosa-regional-platform/blob/main/docs/full-region-provisioning.md#6-consumer-registration--verification).
