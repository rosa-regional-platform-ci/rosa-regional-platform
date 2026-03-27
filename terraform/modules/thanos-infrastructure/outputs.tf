# =============================================================================
# Outputs
# =============================================================================

output "s3_bucket_name" {
  description = "Name of the S3 bucket for Thanos metrics"
  value       = aws_s3_bucket.thanos.id
}

output "s3_bucket_arn" {
  description = "ARN of the S3 bucket"
  value       = aws_s3_bucket.thanos.arn
}

output "s3_bucket_endpoint" {
  description = "S3 endpoint for Thanos configuration (FIPS in US regions, standard otherwise)"
  value       = local.s3_endpoint
}

output "kms_key_arn" {
  description = "ARN of the KMS key for S3 encryption"
  value       = aws_kms_key.thanos.arn
}

output "kms_key_id" {
  description = "ID of the KMS key"
  value       = aws_kms_key.thanos.key_id
}

output "iam_role_arn" {
  description = "ARN of the IAM role for Thanos Receiver (for Pod Identity)"
  value       = aws_iam_role.thanos_receiver.arn
}

output "iam_role_name" {
  description = "Name of the IAM role"
  value       = aws_iam_role.thanos_receiver.name
}

output "region" {
  description = "AWS region"
  value       = data.aws_region.current.name
}

output "fips_enabled" {
  description = "Whether FIPS endpoints are being used (required for FedRAMP in US regions)"
  value       = local.use_fips
}

# =============================================================================
# Helm Values Output
#
# Use this output to generate values-override.yaml for the Helm chart
# =============================================================================

output "helm_values" {
  description = "Values to pass to the Thanos Receiver Helm chart"
  value = {
    aws = {
      region = data.aws_region.current.name
      podIdentity = {
        enabled = true
        roleArn = aws_iam_role.thanos_receiver.arn
      }
    }
    thanosReceiver = {
      objstore = {
        type = "S3"
        config = {
          bucket       = aws_s3_bucket.thanos.id
          endpoint     = local.s3_endpoint
          region       = data.aws_region.current.name
          aws_sdk_auth = true
          sse_config = {
            type       = "SSE-KMS"
            kms_key_id = aws_kms_key.thanos.arn
          }
        }
      }
    }
  }
}
