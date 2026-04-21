output "api_gateway_web_acl_arn" {
  description = "ARN of the WAFv2 Web ACL for the API Gateway stage"
  value       = aws_wafv2_web_acl.api_gateway.arn
}
