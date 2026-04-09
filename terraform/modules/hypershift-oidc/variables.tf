# =============================================================================
# HyperShift OIDC Module - Input Variables
# =============================================================================

variable "cluster_id" {
  description = "Management cluster identifier, used for S3 bucket naming and resource prefixes"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.cluster_id))
    error_message = "cluster_id must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "eks_cluster_name" {
  description = "EKS cluster name for Pod Identity association"
  type        = string
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "oidc_bucket_name" {
  description = "OIDC S3 bucket name --- provisioned in the regional account during the IoT minting step"
  type        = string
}

variable "oidc_bucket_arn" {
  description = "OIDC S3 bucket ARN --- used to scope the HyperShift operator IAM policy"
  type        = string
}

variable "oidc_bucket_region" {
  description = "AWS region of the OIDC S3 bucket"
  type        = string
}

variable "oidc_cloudfront_domain" {
  description = "CloudFront domain for the OIDC issuer URL (without https:// prefix)"
  type        = string
}
