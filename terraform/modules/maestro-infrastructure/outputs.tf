# =============================================================================
# Maestro Infrastructure Module - Outputs
#
# These outputs are used by Helm values and ArgoCD applications to configure
# Maestro components
# =============================================================================

# =============================================================================
# AWS IoT Core Outputs
# =============================================================================

output "iot_mqtt_endpoint" {
  description = "AWS IoT Core MQTT endpoint for broker connection"
  value       = data.aws_iot_endpoint.mqtt.endpoint_address
}

# =============================================================================
# RDS Database Outputs
# =============================================================================

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint (hostname:port)"
  value       = aws_db_instance.maestro.endpoint
}

output "rds_address" {
  description = "RDS PostgreSQL hostname"
  value       = aws_db_instance.maestro.address
}

output "rds_port" {
  description = "RDS PostgreSQL port"
  value       = aws_db_instance.maestro.port
}

output "rds_database_name" {
  description = "Name of the PostgreSQL database"
  value       = aws_db_instance.maestro.db_name
}

output "rds_instance_id" {
  description = "RDS instance identifier"
  value       = aws_db_instance.maestro.id
}

# =============================================================================
# Secrets Manager Outputs
# =============================================================================

output "maestro_server_cert_secret_arn" {
  description = "ARN of Secrets Manager secret containing Maestro Server certificate material"
  value       = aws_secretsmanager_secret.maestro_server_cert.arn
}

output "maestro_server_cert_secret_name" {
  description = "Name of Secrets Manager secret containing Maestro Server certificate material"
  value       = aws_secretsmanager_secret.maestro_server_cert.name
}

output "maestro_server_config_secret_arn" {
  description = "ARN of Secrets Manager secret containing Maestro Server MQTT configuration"
  value       = aws_secretsmanager_secret.maestro_server_config.arn
}

output "maestro_server_config_secret_name" {
  description = "Name of Secrets Manager secret containing Maestro Server MQTT configuration"
  value       = aws_secretsmanager_secret.maestro_server_config.name
}

output "maestro_db_credentials_secret_arn" {
  description = "ARN of Secrets Manager secret containing database credentials"
  value       = aws_secretsmanager_secret.maestro_db_credentials.arn
}

output "maestro_db_credentials_secret_name" {
  description = "Name of Secrets Manager secret containing database credentials"
  value       = aws_secretsmanager_secret.maestro_db_credentials.name
}

# =============================================================================
# IAM Role Outputs
# =============================================================================

output "maestro_server_role_arn" {
  description = "ARN of IAM role for Maestro Server (Pod Identity)"
  value       = aws_iam_role.maestro_server.arn
}

output "maestro_server_role_name" {
  description = "Name of IAM role for Maestro Server"
  value       = aws_iam_role.maestro_server.name
}

# Agent IAM roles are now created in management cluster Terraform
# See terraform/config/management-cluster/ for agent role outputs

# =============================================================================
# Configuration Summary (for easy reference)
# =============================================================================

output "maestro_configuration_summary" {
  description = "Summary of Maestro infrastructure configuration for Helm values"
  value = {
    mqtt = {
      endpoint    = data.aws_iot_endpoint.mqtt.endpoint_address
      port        = 8883
      topicPrefix = "sources/${var.regional_id}/consumers"
    }
    database = {
      host = aws_db_instance.maestro.address
      port = aws_db_instance.maestro.port
      name = aws_db_instance.maestro.db_name
    }
    server = {
      roleArn              = aws_iam_role.maestro_server.arn
      mqttCertSecretName   = aws_secretsmanager_secret.maestro_server_cert.name
      mqttConfigSecretName = aws_secretsmanager_secret.maestro_server_config.name
      dbSecretName         = aws_secretsmanager_secret.maestro_db_credentials.name
    }
  }
}
