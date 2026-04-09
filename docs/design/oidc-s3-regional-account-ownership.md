# OIDC S3 Bucket: Regional Account Ownership

**Last Updated Date**: 2026-04-09
**Status**: Accepted

## Summary

The HyperShift OIDC S3 bucket and CloudFront distribution are provisioned as a single shared
resource per region in the regional cluster (RC) AWS account, owned by
`terraform/config/regional-cluster/`. All management clusters (MCs) in the region write to the
same bucket, with each hosted cluster's documents stored under a path prefix keyed by hosted
cluster ID (`/{hosted_cluster_id}/`). Cross-account write access is restricted to explicitly
enumerated MC account IDs combined with a role-name pattern condition, ensuring only the
HyperShift operator roles in known MC accounts can write OIDC documents.

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
  (for the RHOBS API URL) before switching to the MC account context. The same pattern can carry
  OIDC bucket details to the MC Terraform.

## Decision

One shared S3 bucket + CloudFront distribution per region, provisioned by
`terraform/config/regional-cluster/` as part of RC infrastructure. The bucket is named
`hypershift-oidc-{regional_id}-{rc_account_id}`.

### Bucket policy: explicit account list + role-name condition

OIDC discovery documents are a trust root for hosted cluster identity — they control which
identity providers Kubernetes trusts for service account tokens. A malicious write to
`/.well-known/openid-configuration` or the JWKS document (`/keys.json`) lets an attacker forge
valid service account tokens for any hosted cluster in the region. The write path to this trust
root must therefore be explicitly enumerated, not derived from broad org membership.

The bucket policy uses a dual condition to restrict writes to the minimum necessary principals:

```json
{
  "Sid": "AllowHyperShiftOperatorCrossAccount",
  "Effect": "Allow",
  "Principal": { "AWS": "*" },
  "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
  "Resource": "arn:aws:s3:::hypershift-oidc-<regional_id>-<rc_account_id>/*",
  "Condition": {
    "StringEquals": { "aws:PrincipalAccount": ["<mc_account_id_1>", "<mc_account_id_2>"] },
    "StringLike":   { "aws:PrincipalArn": "arn:aws:iam::*:role/*-hypershift-operator" }
  }
}
```

The dual condition provides:

1. **Account-level scoping** — only the explicitly listed MC accounts can write.
2. **Role-name scoping** — within those accounts, only roles matching `*-hypershift-operator`
   are permitted, preventing any other principal in an MC account from writing OIDC documents.

The HyperShift operator IAM role policy (in the MC account) also explicitly allows the same
S3 actions on the shared bucket ARN. Both policies must permit the action for cross-account
access to succeed (standard AWS cross-account dual-authorization model).

When a new MC is provisioned:
1. Add its account ID to `mc_account_ids` in `deploy/<env>/<region>/pipeline-regional-cluster-inputs/terraform.json`
2. Re-apply the regional cluster Terraform to update the bucket policy
3. Then run the MC provisioning pipeline

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

3. **`aws:PrincipalOrgID` bucket policy**: Allow any IAM principal in the AWS Organization
   to write. Rejected because OIDC documents are a trust root — a compromised developer sandbox
   or CI account within the org would have a write path to cluster identity documents. The blast
   radius (forged credentials for all hosted clusters in the region) is too large to accept for
   the sake of avoiding an account-list update when adding an MC.

4. **Provider alias in MC Terraform**: Add an `aws.regional` provider alias to MC Terraform
   that assumes a role in the RC account to create shared OIDC resources. Rejected because
   it widens MC Terraform's blast radius into the RC account on every apply.

5. **Dedicated OIDC writer role in RC account**: Create a single RC-account role that all MC
   HyperShift operators assume. Rejected: adds a hop without improving security, and the
   trust policy still requires the same account enumeration, just in a different document.

6. **SSM Parameter Store for bucket details**: Write bucket details to SSM instead of reading
   RC Terraform outputs. Rejected: RC Terraform outputs are already authoritative; SSM would
   be an unsynchronised copy.

## Consequences

### Positive

- **Stable issuer URL** — The CloudFront domain never changes, regardless of which MC
  hosts a given control plane. Hosted cluster OIDC credentials survive MC migrations.
- **Tightly scoped trust root write path** — Only named MC accounts + HyperShift operator
  role pattern can write OIDC documents. No org-level exposure.
- **Clean ownership** — OIDC bucket lifecycle is tied to the region, not individual MCs.
  `terraform destroy` on the regional cluster cleans up the shared OIDC endpoint.
- **No MC blast radius into RC** — MC Terraform never assumes a role in the RC account.
- **Auditable** — CloudTrail shows the actual MC principal for every write; no intermediate
  role to trace through.

### Negative / Trade-offs

- **Explicit account list** — `mc_account_ids` must be updated in RC Terraform config and
  re-applied before provisioning each new MC. This is a sequential dependency but is consistent
  with how MC provisioning already works (RC deploys before MCs).
- **RC must be provisioned first** — The RC Terraform apply must complete before the first MC
  in a region can be provisioned (existing sequencing requirement, now also required for OIDC).

## Cross-Cutting Concerns

### Security

- Cross-account S3 access uses the dual-authorization model: both the MC IAM role policy and
  the RC bucket policy must permit the action.
- The bucket policy dual condition (`aws:PrincipalAccount` + `aws:PrincipalArn` StringLike)
  ensures only the expected HyperShift operator roles in listed MC accounts can write.
- CloudFront OAC is the sole read path; the bucket blocks all public access.
- The HyperShift operator IAM role (MC account, EKS Pod Identity) is scoped to the minimum
  required S3 actions on the shared bucket ARN.

### Operability

- RC Terraform manages the full lifecycle of the shared bucket and CloudFront distribution.
- The MC deploy pipeline reads OIDC outputs from RC state using the existing pattern established
  for the RHOBS API URL, keeping the build spec structure consistent.
- Adding an MC requires: (1) add account ID to `mc_account_ids`, (2) apply RC Terraform,
  (3) provision MC. This is documented in `docs/environment-provisioning.md`.
