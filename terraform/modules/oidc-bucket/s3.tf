# =============================================================================
# Private S3 Bucket for OIDC Discovery Documents
#
# Fully private --- only accessible via CloudFront (OAC) for reads and the
# HyperShift operator (cross-account Pod Identity) for writes.
#
# The bucket policy uses aws:PrincipalOrgPaths to allow cross-account writes
# from the OU that contains all management clusters. Combined with a StringLike
# condition on the principal ARN (role name pattern *-hypershift-operator),
# this restricts writes to the HyperShift operator role in any MC account
# within the designated OU — without requiring an explicit per-account list.
#
# The OU path is discovered automatically from the RC account's own OU
# membership (RC and MC accounts share the same OU depth), so no manual
# maintenance is required when new management clusters are provisioned.
#
# The cross-account write statement is omitted when mc_org_paths is empty
# (e.g., on initial regional cluster bootstrap before any MC is configured).
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
    Statement = concat(
      [
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
      ],
      length(var.mc_org_paths) > 0 ? [
        {
          Sid    = "AllowHyperShiftOperatorOrgPath"
          Effect = "Allow"
          Principal = {
            AWS = "*"
          }
          Action = [
            "s3:PutObject",
            "s3:GetObject",
            "s3:DeleteObject",
          ]
          Resource = "${aws_s3_bucket.oidc.arn}/*"
          Condition = {
            # aws:PrincipalOrgPaths is a multi-value key (contains the full OU ancestry
            # chain for the principal). ForAnyValue:StringLike matches if ANY element
            # in the set satisfies the pattern --- required for multi-value condition keys.
            "ForAnyValue:StringLike" = {
              "aws:PrincipalOrgPaths" = var.mc_org_paths
            }
            # Further narrow to HyperShift operator roles within the matched OU
            StringLike = {
              "aws:PrincipalArn" = "arn:aws:iam::*:role/*-hypershift-operator"
            }
          }
        },
      ] : []
    )
  })
}
