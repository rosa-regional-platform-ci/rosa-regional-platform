# =============================================================================
# API Gateway Resource Policy
#
# Controls which AWS accounts can invoke the API. Required for cross-account
# access from Management Clusters.
#
# Two grants:
# 1. MC accounts can POST to /api/v1/receive (metrics ingestion)
# 2. All allowed accounts (RC + MC) can invoke any method (Platform API)
# =============================================================================

resource "aws_api_gateway_rest_api_policy" "main" {
  count       = length(var.allowed_account_ids) > 0 ? 1 : 0
  rest_api_id = aws_api_gateway_rest_api.main.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = "*"
        }
        Action   = "execute-api:Invoke"
        Resource = "arn:aws:execute-api:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:${aws_api_gateway_rest_api.main.id}/*"
        Condition = {
          StringEquals = {
            "aws:PrincipalAccount" = var.allowed_account_ids
          }
        }
      }
    ]
  })
}
