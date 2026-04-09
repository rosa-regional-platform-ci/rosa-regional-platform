# OIDC S3 Bucket: Regional Account Ownership

**Last Updated Date**: 2026-04-09
**Status**: Accepted

## Summary

The HyperShift OIDC S3 bucket and CloudFront distribution are provisioned in the regional cluster (RC) AWS account during the IoT minting pipeline step, which already runs in the RC account context. The management cluster (MC) Terraform receives the bucket name, ARN, region, and CloudFront domain as input variables (read from the IoT minting state) and uses them to configure IAM policies and Secrets Manager. Cross-account write access is granted to the HyperShift operator via a dual IAM role policy (MC) and S3 bucket policy (RC) model with an `aws:PrincipalAccount` condition for defence-in-depth.

## Context

- **Problem Statement**: The OIDC S3 bucket was provisioned in each management cluster's AWS account. As the platform scales to multiple MCs per region, this creates per-account S3 and CloudFront resources that logically belong to the region, not to individual MCs. Consolidating OIDC infrastructure in the regional account aligns ownership with the regional isolation model and simplifies resource management.
- **Constraints**: The HyperShift operator runs on the MC and must retain write access to the S3 bucket. No cross-stack Terraform state references are permitted between RC and MC configurations. The MC pipeline must not require a cross-account provider alias for OIDC resources.
- **Assumptions**: The IoT minting pipeline step already runs in the RC account context and stores its Terraform state in the RC account's S3 bucket. The HyperShift operator IAM role name follows the predictable pattern `{management_cluster_id}-hypershift-operator`, allowing the bucket policy to reference it before the MC infrastructure is deployed.

## Alternatives Considered

1. **Separate RC Terraform module**: Create a new module in `terraform/config/regional-cluster/` that provisions the S3 bucket and CloudFront, with outputs consumed by the MC Terraform via remote state. Rejected because it introduces cross-stack state dependencies and breaks per-MC lifecycle ownership (the RC Terraform runs once per region, not per MC).
2. **Provider alias in MC Terraform**: Add an `aws.regional` provider alias to the existing MC Terraform that assumes a role in the RC account for S3 and CloudFront resources. Rejected because it widens the MC pipeline's blast radius into the RC account and requires managing a cross-account `OrganizationAccountAccessRole` or dedicated provisioner role from the MC Terraform.
3. **IoT minting step (chosen)**: Provision the OIDC S3 bucket and CloudFront distribution in the existing IoT minting pipeline step, which already runs in the RC account. Outputs are stored in the IoT Terraform state and read by `read-iot-state.sh` before the MC Terraform apply. This follows the established pattern for IoT certificate provisioning.
4. **Shared S3 bucket across all MCs**: A single regional bucket with per-MC path prefixes. Rejected because it couples MC lifecycles and complicates teardown (deleting one MC's resources requires careful prefix-scoped cleanup rather than bucket deletion).

## Design Rationale

- **Justification**: The IoT minting step already runs in the RC account context before MC deployment. Adding OIDC bucket provisioning to this step eliminates the need for a cross-account provider alias in the MC Terraform while maintaining per-MC lifecycle ownership. The HyperShift operator role ARN is predictable at mint time (`{cluster_id}-hypershift-operator`), so the S3 bucket policy can grant cross-account write access before the role exists --- AWS validates the account at policy evaluation time, not the role.
- **Evidence**: The IoT minting step has been in production use for Maestro agent certificate provisioning, validating the pattern of provisioning RC-account resources in a pipeline step that precedes MC deployment.
- **Comparison**: Unlike the provider alias approach, the MC Terraform never assumes a role in the RC account, eliminating the blast radius concern. Unlike a separate RC module, there are no cross-stack state dependencies --- the `read-iot-state.sh` script reads outputs from the IoT state and exports them as `TF_VAR_*` environment variables.

## Consequences

### Positive

- Regional infrastructure (S3, CloudFront) is owned by the regional account, aligning with the regional isolation architecture
- Per-MC lifecycle ownership is preserved: creating or destroying an MC automatically manages its OIDC resources (via the IoT minting step's create/destroy logic)
- No cross-account provider alias or `OrganizationAccountAccessRole` assumption from MC Terraform --- the MC pipeline's blast radius is limited to the MC account
- No cross-stack Terraform state dependencies --- outputs flow via `TF_VAR_*` environment variables
- The `aws:PrincipalAccount` condition on the bucket policy provides defence-in-depth against confused deputy attacks

### Negative

- Existing environments require migration: the OIDC issuer URL (CloudFront domain) will change, requiring hosted cluster OIDC configurations to be updated
- The IoT minting step now provisions additional resources (S3, CloudFront), increasing its execution time and scope
- The HyperShift operator role ARN must follow a predictable naming convention; any change to the role naming requires updating the oidc-bucket module

## Cross-Cutting Concerns

### Security:

- Cross-account S3 access uses the principle of least privilege: the bucket policy grants only `PutObject`, `GetObject`, and `DeleteObject` (no `ListBucket`) and is scoped to the MC account via `aws:PrincipalAccount`
- The IAM role policy in the MC account and the bucket policy in the RC account form a dual-authorization model; both must permit access for writes to succeed
- CloudFront OAC remains the sole read path; the bucket stays fully private
- The MC Terraform no longer requires any cross-account IAM role assumption

### Operability:

- The IoT minting step follows the same create/destroy pattern for OIDC resources as it does for IoT certificates, so operators use the same workflow
- Terraform state for OIDC resources lives in the IoT state file in the RC account; `terraform destroy` via the IoT minting step cleanly removes the OIDC bucket and CloudFront distribution
- The `read-iot-state.sh` script exports OIDC outputs alongside IoT certificate outputs, keeping the MC deploy buildspec unchanged in structure
