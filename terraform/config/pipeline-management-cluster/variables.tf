variable "github_repository" {
  type        = string
  description = "GitHub Repository in owner/name format (e.g., 'octocat/hello-world')"
  validation {
    condition     = can(regex("^[^/]+/[^/]+$", var.github_repository))
    error_message = "github_repository must be in 'owner/name' format"
  }
}

variable "github_branch" {
  type        = string
  description = "GitHub Branch to track"
  default     = "main"
}

variable "github_connection_arn" {
  type        = string
  description = "ARN of the shared GitHub CodeStar connection"
}

variable "region" {
  type        = string
  description = "AWS Region"
  default     = "us-east-1"
}

# Optional variables for manual/single-target deployment
variable "target_account_id" {
  type        = string
  description = "Target AWS Account ID (Optional override)"
  default     = ""
}

variable "target_region" {
  type        = string
  description = "Target AWS Region (Optional override)"
  default     = ""
}

variable "target_alias" {
  type        = string
  description = "Target Alias (Optional override)"
  default     = ""
}

variable "target_environment" {
  type        = string
  description = "Target environment (integration, staging, prod)"
  default     = "integration"
}

variable "app_code" {
  type        = string
  description = "Application code for tagging"
  default     = "infra"
}

variable "service_phase" {
  type        = string
  description = "Service phase (dev, staging, prod)"
  default     = "dev"
}

variable "cost_center" {
  type        = string
  description = "Cost center for billing"
  default     = "000"
}

variable "repository_url" {
  type        = string
  description = "Git repository URL for cluster configuration"
}

variable "repository_branch" {
  type        = string
  description = "Git branch to use for cluster configuration"
  default     = "main"
}

variable "management_id" {
  type        = string
  description = "Management cluster identifier for resource naming (e.g., 'mc01')"
}

variable "regional_aws_account_id" {
  type        = string
  description = "AWS account ID where the regional cluster is hosted"
}

variable "enable_bastion" {
  type        = bool
  description = "Enable ECS Fargate bastion for break-glass/development access to the cluster"
  default     = false
}

variable "codebuild_image" {
  type        = string
  description = "ECR image URI for CodeBuild projects (platform image with pre-installed tools)"
}
