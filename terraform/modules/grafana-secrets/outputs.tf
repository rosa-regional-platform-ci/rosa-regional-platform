output "grafana_admin_secret_arn" {
  description = "ARN of the Grafana admin credentials secret in Secrets Manager"
  value       = aws_secretsmanager_secret.grafana_admin.arn
}

output "grafana_secret_key_arn" {
  description = "ARN of the Grafana database secret key in Secrets Manager"
  value       = aws_secretsmanager_secret.grafana_secrets.arn
}
