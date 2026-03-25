# =============================================================================
# Prometheus Remote Write Module - Outputs
# =============================================================================

output "prometheus_role_name" {
  description = "IAM role name for Prometheus"
  value       = aws_iam_role.prometheus.name
}

output "prometheus_role_arn" {
  description = "IAM role ARN for Prometheus"
  value       = aws_iam_role.prometheus.arn
}

output "pod_identity_association_id" {
  description = "EKS Pod Identity association ID"
  value       = aws_eks_pod_identity_association.sigv4_proxy.association_id
}
