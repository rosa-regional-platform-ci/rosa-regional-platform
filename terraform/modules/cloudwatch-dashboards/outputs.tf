# =============================================================================
# Outputs
# =============================================================================

output "overview_dashboard_arn" {
  description = "ARN of the account health overview dashboard"
  value       = aws_cloudwatch_dashboard.overview.dashboard_arn
}

output "platform_api_dashboard_arn" {
  description = "ARN of the Platform API Gateway drilldown dashboard"
  value       = aws_cloudwatch_dashboard.platform_api.dashboard_arn
}

output "rhobs_api_dashboard_arn" {
  description = "ARN of the RHOBS API Gateway drilldown dashboard"
  value       = aws_cloudwatch_dashboard.rhobs_api.dashboard_arn
}
