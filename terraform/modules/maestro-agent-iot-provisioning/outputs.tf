# =============================================================================
# Maestro Agent IoT Provisioning Module - Outputs
# =============================================================================

output "certificate_arn" {
  description = "IoT certificate ARN"
  value       = aws_iot_certificate.maestro_agent.arn
}

output "certificate_id" {
  description = "IoT certificate ID"
  value       = aws_iot_certificate.maestro_agent.id
}

output "iot_policy_name" {
  description = "IoT policy name"
  value       = aws_iot_policy.maestro_agent.name
}

output "iot_policy_arn" {
  description = "IoT policy ARN"
  value       = aws_iot_policy.maestro_agent.arn
}

# =============================================================================
# Certificate Data - For Transfer to Management Account
# =============================================================================

output "agent_cert" {
  description = "Maestro Agent certificate material (SENSITIVE - contains private key)"
  sensitive   = true
  value = {
    certificate = aws_iot_certificate.maestro_agent.certificate_pem
    privateKey  = aws_iot_certificate.maestro_agent.private_key
    caCert      = data.http.aws_iot_root_ca.response_body
  }
}

output "agent_config" {
  description = "Maestro Agent MQTT configuration as YAML string"
  value = {
    # Complete config.yaml file ready to mount
    config = <<-EOT
      # MQTT Broker Configuration for AWS IoT Core
      brokerHost: "${local.iot_mqtt_endpoint}:8883"
      username: ""
      password: ""
      # Certificate files mounted via ASCP CSI driver
      clientCertFile: /mnt/secrets-store/certificate
      clientKeyFile: /mnt/secrets-store/privateKey
      caFile: /mnt/secrets-store/ca.crt
      topics:
        # Agent subscribes to sourceevents for this specific cluster
        sourceEvents: ${var.mqtt_topic_prefix}/${var.management_cluster_id}/sourceevents
        # Agent publishes agentevents back to server
        agentEvents: ${var.mqtt_topic_prefix}/${var.management_cluster_id}/agentevents
    EOT
    # Also include consumer name for command-line args
    consumerName = var.management_cluster_id
  }
}

# =============================================================================
# Metadata - For Tracking and Automation
# =============================================================================

output "metadata" {
  description = "Metadata about the provisioned resources"
  value = {
    management_cluster_id = var.management_cluster_id
    certificate_id        = aws_iot_certificate.maestro_agent.id
    mqtt_endpoint         = local.iot_mqtt_endpoint
    provisioned_at        = timestamp()
  }
}
