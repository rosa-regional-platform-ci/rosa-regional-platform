# =============================================================================
# Private S3 Bucket for OIDC Discovery Documents
#
# Stores OIDC discovery documents and signing keys uploaded by the HyperShift
# operator. Fully private — only accessible via CloudFront (OAC) for reads
# and the HyperShift operator (Pod Identity) for writes.
# =============================================================================

resource "aws_s3_bucket" "oidc" {
  bucket = local.oidc_bucket_name

  tags = merge(
    local.common_tags,
    {
      Name = local.oidc_bucket_name
    }
  )
}

# Block all public access
resource "aws_s3_bucket_public_access_block" "oidc" {
  bucket = aws_s3_bucket.oidc.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Only allow CloudFront OAC to read objects
resource "aws_s3_bucket_policy" "oidc" {
  bucket = aws_s3_bucket.oidc.id

  # Ensure public access block is in place before applying the policy
  depends_on = [aws_s3_bucket_public_access_block.oidc]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
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
    }]
  })
}
