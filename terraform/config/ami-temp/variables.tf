variable "region" {
  description = "AWS region for AMI build resources"
  type        = string
  default     = "us-east-1"
}

variable "ami_consumer_account_ids" {
  description = "AWS account IDs that will launch instances from the built AMIs (granted KMS key access)"
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for id in var.ami_consumer_account_ids : can(regex("^[0-9]{12}$", id))])
    error_message = "Each entry must be a 12-digit AWS account ID"
  }
}

variable "trusted_principal_arns" {
  description = "IAM ARNs (users or roles) allowed to assume the packer-ami-build role"
  type        = list(string)
  validation {
    condition     = alltrue([for arn in var.trusted_principal_arns : can(regex("^arn:aws:iam::[0-9]{12}:(user|role)/.+$", arn))])
    error_message = "Each entry must be a valid IAM user or role ARN (arn:aws:iam::<account>:user/<name> or :role/<name>)"
  }
}
