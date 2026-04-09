# =============================================================================
# Private S3 Bucket for OIDC Discovery Documents
#
# Fully private --- only accessible via CloudFront (OAC) for reads and the
# HyperShift operator (cross-account Pod Identity) for writes.
# =============================================================================

resource "aws_s3_bucket" "oidc" {
  bucket = local.bucket_name

  tags = merge(local.common_tags, { Name = local.bucket_name })
}

resource "aws_s3_bucket_public_access_block" "oidc" {
  bucket = aws_s3_bucket.oidc.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "oidc" {
  bucket = aws_s3_bucket.oidc.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_policy" "oidc" {
  bucket = aws_s3_bucket.oidc.id

  depends_on = [
    aws_s3_bucket_public_access_block.oidc,
    aws_s3_bucket_server_side_encryption_configuration.oidc,
  ]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontOAC"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.oidc.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.oidc.arn
          }
        }
      },
      {
        Sid    = "AllowHyperShiftOperatorCrossAccount"
        Effect = "Allow"
        Principal = {
          AWS = local.hypershift_operator_role_arn
        }
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
        ]
        Resource = "${aws_s3_bucket.oidc.arn}/*"
        Condition = {
          StringEquals = {
            "aws:PrincipalAccount" = var.mc_account_id
          }
        }
      },
    ]
  })
}
