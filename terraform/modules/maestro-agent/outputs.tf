# =============================================================================
# Maestro Agent Module - Outputs
# =============================================================================

output "maestro_agent_role_name" {
  description = "IAM role name for Maestro Agent"
  value       = aws_iam_role.maestro_agent.name
}

output "maestro_agent_role_arn" {
  description = "IAM role ARN for Maestro Agent"
  value       = aws_iam_role.maestro_agent.arn
}

output "maestro_agent_cert_secret_name" {
  description = "Secrets Manager secret name for agent MQTT certificate"
  value       = aws_secretsmanager_secret.maestro_agent_cert.name
}

output "maestro_agent_config_secret_name" {
  description = "Secrets Manager secret name for agent MQTT configuration"
  value       = aws_secretsmanager_secret.maestro_agent_config.name
}

output "cluster_id" {
  description = "Management cluster identifier"
  value       = var.management_id
}

output "pod_identity_association_id" {
  description = "EKS Pod Identity association ID"
  value       = aws_eks_pod_identity_association.maestro_agent.association_id
}
