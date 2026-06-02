# =============================================================================
# OIDC Bucket Writer IAM Role
#
# RC-side role that MC hypershift operators assume via cross-account Pod
# Identity to upload OIDC discovery documents to the regional S3 bucket.
# Trust is OU-based so new MC accounts get access automatically.
#
# This follows the same pattern as dns-zone-operator: the cross-account
# boundary is at STS AssumeRole (where OU conditions work), not at S3/KMS
# resource policies (where they don't for Pod Identity via VPC endpoints).
# =============================================================================

resource "aws_iam_role" "oidc_bucket_writer" {
  name        = "${var.regional_id}-oidc-bucket-writer"
  description = "Cross-account role for MC hypershift operators to manage OIDC documents in S3"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        AWS = "*"
      }
      Action = [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
      Condition = {
        StringEquals = {
          "aws:PrincipalOrgID" = split("/", var.region_ou_path)[0]
        }
        "ForAnyValue:StringLike" = {
          "aws:PrincipalOrgPaths" = "${var.region_ou_path}*"
        }
      }
    }]
  })

  tags = {
    Name = "${var.regional_id}-oidc-bucket-writer"
  }
}

resource "aws_iam_role_policy" "oidc_bucket_writer_s3" {
  name = "${var.regional_id}-oidc-bucket-writer-s3"
  role = aws_iam_role.oidc_bucket_writer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:ListBucket",
      ]
      Resource = [
        aws_s3_bucket.oidc.arn,
        "${aws_s3_bucket.oidc.arn}/*",
      ]
    }]
  })
}

resource "aws_iam_role_policy" "oidc_bucket_writer_kms" {
  name = "${var.regional_id}-oidc-bucket-writer-kms"
  role = aws_iam_role.oidc_bucket_writer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "kms:GenerateDataKey",
        "kms:Decrypt",
        "kms:DescribeKey",
      ]
      Resource = aws_kms_key.oidc.arn
    }]
  })
}
