# =============================================================================
# Outputs
# =============================================================================

output "s3_bucket_name" {
  description = "Name of the S3 bucket for Loki logs"
  value       = aws_s3_bucket.loki.id
}

output "s3_bucket_arn" {
  description = "ARN of the S3 bucket"
  value       = aws_s3_bucket.loki.arn
}

output "s3_bucket_endpoint" {
  description = "S3 endpoint for Loki configuration (FIPS in US regions, standard otherwise)"
  value       = local.s3_endpoint
}

output "kms_key_arn" {
  description = "ARN of the KMS key for S3 encryption"
  value       = aws_kms_key.loki.arn
}

output "kms_key_id" {
  description = "ID of the KMS key"
  value       = aws_kms_key.loki.key_id
}

output "writer_role_arn" {
  description = "ARN of the IAM role for Loki (all components share this via a single ServiceAccount)"
  value       = aws_iam_role.loki_writer.arn
}

output "region" {
  description = "AWS region"
  value       = data.aws_region.current.region
}

output "fips_enabled" {
  description = "Whether FIPS endpoints are being used (required for FedRAMP in US regions)"
  value       = local.use_fips
}
