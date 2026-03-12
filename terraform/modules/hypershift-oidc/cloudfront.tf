# =============================================================================
# CloudFront Distribution for OIDC Endpoint
#
# Provides a public HTTPS endpoint for the OIDC discovery documents stored
# in the private S3 bucket. Uses Origin Access Control (OAC) so the bucket
# stays fully private.
#
# The CloudFront domain (e.g. d1234abcdef.cloudfront.net) becomes the OIDC
# issuer base URL. Each hosted cluster's documents live under a path prefix:
#   https://<domain>/<cluster-name>/.well-known/openid-configuration
#   https://<domain>/<cluster-name>/keys.json
# =============================================================================

resource "aws_cloudfront_origin_access_control" "oidc" {
  name                              = "${var.cluster_id}-oidc"
  description                       = "OAC for HyperShift OIDC S3 bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "oidc" {
  enabled     = true
  comment     = "OIDC endpoint for management cluster ${var.cluster_id}"
  price_class = "PriceClass_100" # US, Canada, Europe only — cheapest

  origin {
    domain_name              = aws_s3_bucket.oidc.bucket_regional_domain_name
    origin_id                = "oidc-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.oidc.id
  }

  default_cache_behavior {
    target_origin_id       = "oidc-s3"
    viewer_protocol_policy = "https-only"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    # OIDC documents change infrequently — cache for 1 hour
    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = merge(
    local.common_tags,
    {
      Name = "${var.cluster_id}-oidc"
    }
  )
}
