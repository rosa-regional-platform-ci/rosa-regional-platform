# OIDC S3 Bucket: Regional Account Ownership

**Last Updated Date**: 2026-04-09

## Summary

The HyperShift OIDC S3 bucket and CloudFront distribution are moved from the management cluster (MC) AWS account to the regional cluster (RC) AWS account, using a Terraform provider alias (`aws.regional`) in the management cluster configuration. Cross-account write access is granted to the HyperShift operator via a dual IAM role policy (MC) and S3 bucket policy (RC) model with an `aws:PrincipalAccount` condition for defence-in-depth.

## Context

- **Problem Statement**: The OIDC S3 bucket was provisioned in each management cluster's AWS account. As the platform scales to multiple MCs per region, this creates per-account S3 and CloudFront resources that logically belong to the region, not to individual MCs. Consolidating OIDC infrastructure in the regional account aligns ownership with the regional isolation model and simplifies resource management.
- **Constraints**: The HyperShift operator runs on the MC and must retain write access to the S3 bucket. The MC Terraform must remain the lifecycle owner of the OIDC resources because each MC has its own bucket and CloudFront distribution. No cross-stack Terraform state references are permitted between RC and MC configurations.
- **Assumptions**: The `OrganizationAccountAccessRole` is available in the regional account for cross-account provider assumption (same pattern already used for the primary MC provider and the RC's `aws.central` provider for DNS delegation).

## Alternatives Considered

1. **Separate RC Terraform module**: Create a new module in `terraform/config/regional-cluster/` that provisions the S3 bucket and CloudFront, with outputs consumed by the MC Terraform via remote state. Rejected because it introduces cross-stack state dependencies and breaks per-MC lifecycle ownership (the RC Terraform runs once per region, not per MC).
2. **Provider alias in MC Terraform (chosen)**: Add an `aws.regional` provider alias to the existing MC Terraform that assumes a role in the RC account. The `hypershift-oidc` module uses this alias for S3 and CloudFront resources while keeping IAM in the MC account. This preserves per-MC lifecycle ownership with no cross-stack references.
3. **Shared S3 bucket across all MCs**: A single regional bucket with per-MC path prefixes. Rejected because it couples MC lifecycles and complicates teardown (deleting one MC's resources requires careful prefix-scoped cleanup rather than bucket deletion).

## Design Rationale

- **Justification**: The provider alias approach keeps all OIDC resources under the MC Terraform lifecycle (create and destroy with the MC) while placing the actual S3 bucket and CloudFront distribution in the correct account. This mirrors the existing `aws.central` pattern in the RC Terraform for DNS delegation.
- **Evidence**: The `aws.central` provider alias in `terraform/config/regional-cluster/main.tf` has been in production use for cross-account Route53 delegation, validating this pattern.
- **Comparison**: Unlike the separate RC module approach, this avoids `terraform_remote_state` data sources and the operational complexity of coordinating RC and MC Terraform applies. Unlike a shared bucket, each MC retains its own isolated OIDC namespace.

## Consequences

### Positive

- Regional infrastructure (S3, CloudFront) is owned by the regional account, aligning with the regional isolation architecture
- Per-MC lifecycle ownership is preserved: creating or destroying an MC automatically manages its OIDC resources
- No cross-stack Terraform state dependencies
- The `aws:PrincipalAccount` condition on the bucket policy provides defence-in-depth against confused deputy attacks

### Negative

- Existing environments require migration: the OIDC issuer URL (CloudFront domain) will change, requiring hosted cluster OIDC configurations to be updated
- The MC Terraform pipeline gains write access to the RC account for S3 and CloudFront resources, widening the MC pipeline's blast radius
- `force_destroy` is removed from the S3 bucket to prevent accidental deletion of OIDC documents that hosted clusters depend on; bucket teardown requires explicit object cleanup

## Cross-Cutting Concerns

### Security:

- Cross-account S3 access uses the principle of least privilege: the bucket policy grants only `PutObject`, `GetObject`, and `DeleteObject` (no `ListBucket`) and is scoped to the MC account via `aws:PrincipalAccount`
- The IAM role policy in the MC account and the bucket policy in the RC account form a dual-authorization model; both must permit access for writes to succeed
- CloudFront OAC remains the sole read path; the bucket stays fully private

### Operability:

- The provider alias pattern is already established in the codebase (`aws.central` in RC Terraform), so operators are familiar with the cross-account model
- Terraform state for OIDC resources remains in the MC state file, so `terraform destroy` on an MC cleanly removes its OIDC bucket and CloudFront distribution
