# =============================================================================
# Grafana CloudWatch Logs Module - Outputs
# =============================================================================

output "role_arn" {
  description = "IAM role ARN (primary or reader depending on mode)"
  value       = var.mode == "primary" ? aws_iam_role.grafana_primary[0].arn : aws_iam_role.grafana_reader[0].arn
}

output "role_name" {
  description = "IAM role name (primary or reader depending on mode)"
  value       = var.mode == "primary" ? aws_iam_role.grafana_primary[0].name : aws_iam_role.grafana_reader[0].name
}
