# =============================================================================
# RHOBS API Gateway Resource Policy
#
# Restricts access to accounts within the same AWS Organization. Any account
# in the org can POST to /api/v1/receive (MC accounts for metrics ingestion).
# The org ID is resolved dynamically — no account IDs needed in config.
# =============================================================================

data "aws_organizations_organization" "current" {}

resource "aws_api_gateway_rest_api_policy" "rhobs" {
  rest_api_id = aws_api_gateway_rest_api.rhobs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowOrgMetricsIngestion"
        Effect = "Allow"
        Principal = {
          AWS = "*"
        }
        Action   = "execute-api:Invoke"
        Resource = "arn:aws:execute-api:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:${aws_api_gateway_rest_api.rhobs.id}/*/POST/api/v1/receive"
        Condition = {
          StringEquals = {
            "aws:PrincipalOrgID" = data.aws_organizations_organization.current.id
          }
        }
      }
    ]
  })
}
