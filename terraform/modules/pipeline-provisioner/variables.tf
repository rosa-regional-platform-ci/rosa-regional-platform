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

variable "region" {
  type        = string
  description = "AWS Region for the Pipeline Provisioner"
  default     = "us-east-1"
}

variable "environment" {
  type        = string
  description = "Environment to monitor (e.g., integration, staging, production)"
  default     = "staging"
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.environment))
    error_message = "environment must be a single path segment (lowercase letters, digits, hyphen)."
  }
}

variable "github_connection_arn" {
  type        = string
  description = "ARN of the shared GitHub CodeStar connection"
}

variable "codebuild_image" {
  type        = string
  description = "ECR image URI for CodeBuild projects (platform image with pre-installed tools)"

  validation {
    condition     = length(var.codebuild_image) > 0
    error_message = "codebuild_image must be a non-empty ECR image URI"
  }
}
