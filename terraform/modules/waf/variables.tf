variable "cluster_id" {
  description = "Unique cluster identifier used as a name prefix for all resources"
  type        = string
}

variable "api_gateway_stage_arn" {
  description = "ARN of the API Gateway stage to associate the WAF Web ACL with"
  type        = string
}
