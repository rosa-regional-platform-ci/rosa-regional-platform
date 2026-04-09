# =============================================================================
# HyperShift OIDC Module - Outputs
# =============================================================================

# S3 (pass-through from IoT minting step)
output "oidc_bucket_name" {
  description = "S3 bucket name for OIDC discovery documents"
  value       = var.oidc_bucket_name
}

output "oidc_bucket_arn" {
  description = "S3 bucket ARN for OIDC discovery documents"
  value       = var.oidc_bucket_arn
}

# CloudFront (pass-through from IoT minting step)
output "cloudfront_domain_name" {
  description = "CloudFront domain name --- OIDC issuer base URL"
  value       = var.oidc_cloudfront_domain
}

# IAM / Pod Identity
output "role_arn" {
  description = "IAM role ARN for the HyperShift operator"
  value       = aws_iam_role.hypershift_operator.arn
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

# External Secrets Operator
output "external_secrets_operator_role_arn" {
  description = "IAM role ARN for External Secrets Operator"
  value       = aws_iam_role.external_secrets_operator.arn
}

output "external_secrets_operator_pod_identity_association_id" {
  description = "Pod Identity association ID for External Secrets Operator"
  value       = aws_eks_pod_identity_association.external_secrets_operator.association_id
}
