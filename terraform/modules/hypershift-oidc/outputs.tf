# =============================================================================
# HyperShift OIDC Module - Outputs
# =============================================================================

# S3
output "oidc_bucket_name" {
  description = "S3 bucket name for OIDC discovery documents"
  value       = aws_s3_bucket.oidc.id
}

output "oidc_bucket_arn" {
  description = "S3 bucket ARN for OIDC discovery documents"
  value       = aws_s3_bucket.oidc.arn
}

# CloudFront
output "cloudfront_domain_name" {
  description = "CloudFront domain name — this is the OIDC issuer base URL (prefix with https://)"
  value       = aws_cloudfront_distribution.oidc.domain_name
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID"
  value       = aws_cloudfront_distribution.oidc.id
}

# IAM / Pod Identity
output "role_arn" {
  description = "IAM role ARN for the HyperShift operator"
  value       = aws_iam_role.hypershift_operator.arn
}

output "pod_identity_association_id" {
  description = "Pod Identity association ID for the HyperShift operator"
  value       = aws_eks_pod_identity_association.hypershift_operator.association_id
}

# Installer
output "installer_role_arn" {
  description = "IAM role ARN for the HyperShift install Job"
  value       = aws_iam_role.hypershift_installer.arn
}

output "config_secret_name" {
  description = "Secrets Manager secret name for HyperShift configuration"
  value       = aws_secretsmanager_secret.hypershift_config.name
}

# OpenShift Pull Secret
output "openshift_pull_secret_name" {
  description = "Secrets Manager secret name for OpenShift pull secret"
  value       = aws_secretsmanager_secret.openshift_pull_secret.name
}

output "openshift_pull_secret_arn" {
  description = "Secrets Manager secret ARN for OpenShift pull secret"
  value       = aws_secretsmanager_secret.openshift_pull_secret.arn
}

# External Secrets Operator
output "external_secrets_operator_role_arn" {
  description = "IAM role ARN for External Secrets Operator"
  value       = aws_iam_role.external_secrets_operator.arn
}

output "external_secrets_operator_pod_identity_association_id" {
  description = "Pod Identity association ID for External Secrets Operator"
  value       = aws_eks_pod_identity_association.external_secrets_operator.association_id
}
