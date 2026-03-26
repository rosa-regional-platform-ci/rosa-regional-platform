# =============================================================================
# Outputs
# =============================================================================

output "invoke_url" {
  description = "RHOBS API Gateway invoke URL for Thanos remote write"
  value       = aws_apigatewayv2_stage.default.invoke_url
}

output "api_id" {
  description = "RHOBS HTTP API Gateway ID"
  value       = aws_apigatewayv2_api.rhobs.id
}
