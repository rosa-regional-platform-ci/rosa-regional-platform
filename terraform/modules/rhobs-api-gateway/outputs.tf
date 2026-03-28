# =============================================================================
# RHOBS API Gateway - Outputs
# =============================================================================

output "invoke_url" {
  description = "RHOBS API Gateway invoke URL"
  value       = aws_api_gateway_stage.rhobs.invoke_url
}

output "api_id" {
  description = "RHOBS API Gateway REST API ID"
  value       = aws_api_gateway_rest_api.rhobs.id
}
