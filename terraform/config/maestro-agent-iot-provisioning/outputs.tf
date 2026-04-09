# =============================================================================
# Maestro Agent IoT Provisioning - Outputs
# =============================================================================

# Pass-through outputs from module
output "certificate_arn" {
  description = "IoT certificate ARN"
  value       = module.maestro_agent_iot.certificate_arn
}

output "certificate_id" {
  description = "IoT certificate ID"
  value       = module.maestro_agent_iot.certificate_id
}

output "iot_policy_name" {
  description = "IoT policy name"
  value       = module.maestro_agent_iot.iot_policy_name
}

output "iot_policy_arn" {
  description = "IoT policy ARN"
  value       = module.maestro_agent_iot.iot_policy_arn
}

output "agent_cert" {
  description = "Maestro Agent certificate material (SENSITIVE)"
  sensitive   = true
  value       = module.maestro_agent_iot.agent_cert
}

output "agent_config" {
  description = "Maestro Agent MQTT configuration"
  value       = module.maestro_agent_iot.agent_config
}

output "metadata" {
  description = "Provisioning metadata"
  value       = module.maestro_agent_iot.metadata
}

output "oidc_bucket_name" {
  value = module.oidc_bucket.bucket_name
}

output "oidc_bucket_arn" {
  value = module.oidc_bucket.bucket_arn
}

output "oidc_bucket_region" {
  value = module.oidc_bucket.bucket_region
}

output "oidc_cloudfront_domain" {
  value = module.oidc_bucket.cloudfront_domain
}
