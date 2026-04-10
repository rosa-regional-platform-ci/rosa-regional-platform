# OIDC S3 Bucket: Regional Account Ownership

**Last Updated Date**: 2026-04-10
**Status**: Accepted

## Summary

The HyperShift OIDC S3 bucket and CloudFront distribution are provisioned as a single shared
resource per region in the regional cluster (RC) AWS account, owned by
`terraform/config/regional-cluster/`. All management clusters (MCs) in the region write to the
same bucket, with each hosted cluster's documents stored under a path prefix keyed by hosted
cluster ID (`/{hosted_cluster_id}/`). Cross-account write access is granted to the HyperShift
operator role in any account within the same AWS Organizations OU as the RC account, discovered
automatically at RC pipeline apply time — no per-account configuration is required when
provisioning new management clusters.

## Context

- **Problem Statement**: The OIDC S3 bucket was initially provisioned in each management
  cluster's AWS account, giving each MC its own CloudFront URL. As the platform scales to
  multiple MCs per region, each MC's CloudFront domain becomes the OIDC issuer URL for all
  hosted clusters it runs. Migrating a hosted cluster between MCs would change its issuer URL,
  invalidating all workload identity tokens and requiring credential rotation across all workloads
  in the cluster. A stable, regional OIDC endpoint is required.
- **Constraints**: The HyperShift operator runs on the MC and must retain write access to the S3
  bucket. No cross-stack Terraform state references are permitted between RC and MC
  configurations. The MC pipeline must not require a cross-account provider alias.
- **Assumptions**: The MC provisioning pipeline already reads outputs from RC Terraform state
  (for the RHOBS API URL) before switching to the MC account context. RC and MC accounts
  reside at the same OU depth within the AWS Organization.

## Decision

One shared S3 bucket + CloudFront distribution per region, provisioned by
`terraform/config/regional-cluster/` as part of RC infrastructure. The bucket is named
`hypershift-oidc-{regional_id}-{rc_account_id}`.

### Bucket policy: `aws:PrincipalOrgPaths` + role-name pattern

`aws:PrincipalOrgPaths` identifies the OU ancestry path for an IAM principal. By matching on
the OU that contains all platform accounts (RC + MCs share the same OU depth), write access
is automatically granted to any MC account added to that OU — without maintaining an explicit
account list. The condition is combined with a `StringLike` on `aws:PrincipalArn` to further
narrow the grant to HyperShift operator roles only:

```json
{
  "Sid": "AllowHyperShiftOperatorOrgPath",
  "Effect": "Allow",
  "Principal": { "AWS": "*" },
  "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
  "Resource": "arn:aws:s3:::hypershift-oidc-<regional_id>-<rc_account_id>/*",
  "Condition": {
    "ForAnyValue:StringLike": {
      "aws:PrincipalOrgPaths": ["o-aa111bb222cc/r-ab12/ou-ab12-cd34ef56/*"]
    },
    "StringLike": {
      "aws:PrincipalArn": "arn:aws:iam::*:role/*-hypershift-operator"
    }
  }
}
```

`ForAnyValue:StringLike` is required because `aws:PrincipalOrgPaths` is a multi-value condition
key (it contains the full OU ancestry chain for the principal, not just the immediate parent OU).
The condition evaluates true if any element in the set matches the pattern.

The dual condition provides:

1. **OU-level scoping** — only accounts in the designated OU can write. Developer sandboxes or
   CI accounts in other OUs have no write path, even with broad S3 permissions.
2. **Role-name scoping** — within the OU, only roles matching `*-hypershift-operator` are
   permitted, preventing any other principal from writing OIDC documents.

The HyperShift operator IAM role policy (in the MC account) also explicitly allows the same
S3 actions on the shared bucket ARN. Both policies must permit the action for cross-account
access to succeed (standard AWS cross-account dual-authorization model).

### Automatic OU path discovery

The RC provisioning pipeline (`provision-infra-rc.sh`) discovers the OU path automatically
before running `terraform apply`, using AWS Organizations read APIs (permitted from any member
account — no management account access required):

```bash
OU_ID=$(aws organizations list-parents --child-id "${TARGET_ACCOUNT_ID}" \
    --query 'Parents[0].Id' --output text)
ROOT_ID=$(aws organizations list-roots --query 'Roots[0].Id' --output text)
ORG_ID=$(aws organizations describe-organization --query 'Organization.Id' --output text)
TF_VAR_mc_org_paths="[\"${ORG_ID}/${ROOT_ID}/${OU_ID}/*\"]"
```

Because RC and MC accounts share the same OU depth, the RC account's own OU path is the
correct value. No per-MC configuration is required — new MCs in the same OU automatically
inherit write access.

### How MC Terraform learns the bucket details

The MC provisioning pipeline (`provision-infra-mc.sh`) reads OIDC outputs from RC Terraform
state in the same step that reads the RHOBS API URL — before switching to the MC account:

```
provision-infra-mc.sh
  ├─ use_rc_account
  ├─ source read-iot-state.sh            # reads Maestro IoT cert/config from IoT state
  ├─ terraform init (regional-cluster state)
  ├─ terraform output oidc_bucket_name   → TF_VAR_oidc_bucket_name
  ├─ terraform output oidc_bucket_arn    → TF_VAR_oidc_bucket_arn
  ├─ terraform output oidc_bucket_region → TF_VAR_oidc_bucket_region
  ├─ terraform output oidc_cloudfront_domain → TF_VAR_oidc_cloudfront_domain
  ├─ use_mc_account
  └─ terraform apply management-cluster/
```

The IoT minting step (`iot-mint.sh`) creates only Maestro IoT certificates/policies;
OIDC bucket provisioning has been removed from the minting step entirely.

## Alternatives Considered

1. **Per-MC bucket in RC account (previous implementation)**: One bucket per MC, provisioned
   during the IoT minting step, with a per-account `aws:PrincipalAccount` bucket policy
   condition. Rejected because each MC gets a different CloudFront URL, making hosted cluster
   migration between MCs impossible without rotating workload credentials.

2. **Per-MC bucket in MC account**: Original approach. Rejected for the same reason, plus
   the additional concern that OIDC infrastructure logically belongs to the region, not to
   individual MCs.

3. **Explicit `mc_account_ids` list**: Restrict writes to an enumerated list of MC account IDs
   combined with a role-name StringLike. Provides tighter scoping but requires re-applying RC
   Terraform when each new MC is provisioned. Rejected in favour of the OU-path approach, which
   achieves the same isolation (MCs are in the same OU, other org accounts are not) without
   per-MC operational overhead.

4. **`aws:PrincipalOrgID` (full org)**: Allow any IAM principal in the entire AWS Organization.
   Rejected because OIDC documents are a trust root — a compromised developer sandbox or CI
   account in the org would have a write path. The blast radius (forged credentials for all
   hosted clusters in the region) is unacceptable.

5. **Provider alias in MC Terraform**: Add an `aws.regional` provider alias to MC Terraform
   that assumes a role in the RC account to create shared OIDC resources. Rejected because
   it widens MC Terraform's blast radius into the RC account on every apply.

6. **Dedicated OIDC writer role in RC account**: Create a single RC-account role that all MC
   HyperShift operators assume. Rejected: adds a hop without improving security, and the
   trust policy still requires OU or account enumeration.

7. **SSM Parameter Store for bucket details**: Write bucket details to SSM instead of reading
   RC Terraform outputs. Rejected: RC Terraform outputs are already authoritative; SSM would
   be an unsynchronised copy.

## Consequences

### Positive

- **Stable issuer URL** — The CloudFront domain never changes, regardless of which MC
  hosts a given control plane. Hosted cluster OIDC credentials survive MC migrations.
- **Zero-touch MC scaling** — New MC accounts provisioned into the same OU automatically
  inherit write access with no RC Terraform changes.
- **Tighter than full-org, maintenance-free** — OU scoping excludes other org accounts
  (dev sandboxes, CI accounts) without requiring an explicit per-MC account list.
- **Clean ownership** — OIDC bucket lifecycle is tied to the region, not individual MCs.
- **No MC blast radius into RC** — MC Terraform never assumes a role in the RC account.
- **Automatic discovery** — The OU path is discovered from the RC account itself at RC
  pipeline apply time; no operator input required.

### Negative / Trade-offs

- **OU boundary assumption** — Relies on MC and RC accounts being in the same OU. If the
  org structure changes (e.g., MCs moved to a child OU), the bucket policy must be updated.
- **`aws:PrincipalOrgPaths` scope** — Any account in the OU can write (not just MC accounts),
  if it has an IAM policy permitting S3 writes to the specific bucket ARN. The `StringLike`
  role-name condition provides a second layer of restriction in practice.
- **RC must be provisioned first** — The RC Terraform apply must complete before the first MC
  in a region can be provisioned (existing sequencing requirement, now also required for OIDC).

## Cross-Cutting Concerns

### Security

- Cross-account S3 access uses the dual-authorization model: both the MC IAM role policy and
  the RC bucket policy must permit the action.
- The `ForAnyValue:StringLike` + `aws:PrincipalOrgPaths` condition correctly handles the
  multi-value nature of the condition key (full OU ancestry chain).
- CloudFront OAC is the sole read path; the bucket blocks all public access.
- The HyperShift operator IAM role (MC account, EKS Pod Identity) is scoped to the minimum
  required S3 actions on the shared bucket ARN.

### Operability

- RC Terraform manages the full lifecycle of the shared bucket and CloudFront distribution.
- The MC deploy pipeline reads OIDC outputs from RC state using the existing pattern established
  for the RHOBS API URL, keeping the build spec structure consistent.
- The OU path is logged during the RC pipeline apply for auditability.
