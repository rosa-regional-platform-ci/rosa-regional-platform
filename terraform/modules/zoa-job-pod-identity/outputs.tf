output "role_arn" {
  description = "ARN of the ZOA job IAM role"
  value       = aws_iam_role.zoa_job.arn
}
