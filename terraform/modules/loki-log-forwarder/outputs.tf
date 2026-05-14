# =============================================================================
# Loki Log Forwarder Module - Outputs
# =============================================================================

output "loki_forwarder_role_name" {
  description = "IAM role name for Loki log forwarder"
  value       = aws_iam_role.loki_forwarder.name
}

output "loki_forwarder_role_arn" {
  description = "IAM role ARN for Loki log forwarder"
  value       = aws_iam_role.loki_forwarder.arn
}

output "pod_identity_association_id" {
  description = "EKS Pod Identity association ID"
  value       = aws_eks_pod_identity_association.sigv4_proxy_logs.association_id
}
