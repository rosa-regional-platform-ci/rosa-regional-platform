# =============================================================================
# Private S3 Bucket for OIDC Discovery Documents
#
# Stores OIDC discovery documents and signing keys uploaded by the HyperShift
# operator. Fully private — only accessible via CloudFront (OAC) for reads
# and the HyperShift operator (Pod Identity) for writes.
#
# The bucket is provisioned in the regional account via the aws.regional
# provider alias. The management cluster's HyperShift operator accesses it
# cross-account: the IAM role policy (management account) and this bucket
# policy (regional account) together grant write access.
# =============================================================================

resource "aws_s3_bucket" "oidc" {
  provider = aws.regional
  bucket   = local.oidc_bucket_name

  tags = merge(
    local.common_tags,
    {
      Name = local.oidc_bucket_name
    }
  )
}

# Block all public access
resource "aws_s3_bucket_public_access_block" "oidc" {
  provider = aws.regional
  bucket   = aws_s3_bucket.oidc.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Allow CloudFront OAC to read objects, and the HyperShift operator
# (management account) to write objects cross-account.
resource "aws_s3_bucket_policy" "oidc" {
  provider = aws.regional
  bucket   = aws_s3_bucket.oidc.id

  # Ensure public access block is in place before applying the policy
  depends_on = [aws_s3_bucket_public_access_block.oidc]

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
          AWS = aws_iam_role.hypershift_operator.arn
        }
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
        ]
        Resource = "${aws_s3_bucket.oidc.arn}/*"
        Condition = {
          StringEquals = {
            "aws:PrincipalAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
    ]
  })
}
