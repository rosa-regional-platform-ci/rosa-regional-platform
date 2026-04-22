# =============================================================================
# RHOBS API Gateway - Variables
# =============================================================================

variable "regional_id" {
  description = "Regional cluster identifier for resource naming"
  type        = string
}

variable "vpc_link_id" {
  description = "VPC Link ID (reused from the api-gateway module)"
  type        = string
}

variable "alb_arn" {
  description = "Internal ALB ARN (for REST API integration_target)"
  type        = string
}

variable "alb_dns_name" {
  description = "Internal ALB DNS name (for REST API integration URI)"
  type        = string
}

variable "alb_certificate_arn" {
  description = "ACM certificate ARN for the internal ALB. When set, the integration URI uses HTTPS; otherwise HTTP."
  type        = string
  default     = ""
}

variable "stage_name" {
  description = "API Gateway stage name"
  type        = string
  default     = "prod"
}
