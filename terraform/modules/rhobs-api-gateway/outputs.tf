# =============================================================================
# Outputs
# =============================================================================

# -----------------------------------------------------------------------------
# API Gateway
# -----------------------------------------------------------------------------

output "invoke_url" {
  description = "RHOBS API Gateway invoke URL"
  value       = aws_api_gateway_stage.rhobs.invoke_url
}

output "api_id" {
  description = "RHOBS API Gateway REST API ID"
  value       = aws_api_gateway_rest_api.rhobs.id
}

# -----------------------------------------------------------------------------
# ALB and Target Groups
# -----------------------------------------------------------------------------

output "alb_arn" {
  description = "RHOBS internal ALB ARN"
  value       = aws_lb.rhobs.arn
}

output "alb_dns_name" {
  description = "RHOBS internal ALB DNS name"
  value       = aws_lb.rhobs.dns_name
}

output "thanos_receive_target_group_arn" {
  description = "Target group ARN for Thanos Receive TargetGroupBinding"
  value       = aws_lb_target_group.thanos_receive.arn
}

output "thanos_query_target_group_arn" {
  description = "Target group ARN for Thanos Query Frontend TargetGroupBinding"
  value       = aws_lb_target_group.thanos_query.arn
}
