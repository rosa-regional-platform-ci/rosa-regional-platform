# =============================================================================
# RHOBS API Gateway Resource Policy
#
# Restricts access to MC accounts only. Since this is a dedicated API Gateway
# (separate from the Platform API), the policy is simple: allow MC accounts
# to POST to /api/v1/receive. No other callers need access.
# =============================================================================

resource "aws_api_gateway_rest_api_policy" "rhobs" {
  count       = length(var.allowed_account_ids) > 0 ? 1 : 0
  rest_api_id = aws_api_gateway_rest_api.rhobs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowMCMetricsIngestion"
        Effect = "Allow"
        Principal = {
          AWS = "*"
        }
        Action   = "execute-api:Invoke"
        Resource = "arn:aws:execute-api:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:${aws_api_gateway_rest_api.rhobs.id}/*/POST/api/v1/receive"
        Condition = {
          StringEquals = {
            "aws:PrincipalAccount" = var.allowed_account_ids
          }
        }
      }
    ]
  })
}
