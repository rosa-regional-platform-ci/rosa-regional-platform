# =============================================================================
# Thanos Receive API Gateway Integration
#
# Explicit /api/v1/receive resource with HTTP (non-proxy) integration.
# Uses HTTP instead of HTTP_PROXY to guarantee that the THANOS-TENANT header
# is set from the verified IAM account ID and cannot be spoofed by callers.
#
# Flow: POST /api/v1/receive -> VPC Link -> ALB -> Thanos Receive (:19291)
# =============================================================================

# -----------------------------------------------------------------------------
# Resource chain: /api -> /api/v1 -> /api/v1/receive
#
# REST API resolves explicit resources before {proxy+}, so this takes
# priority over the catch-all without conflicting.
# -----------------------------------------------------------------------------

resource "aws_api_gateway_resource" "api" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "api"
}

resource "aws_api_gateway_resource" "api_v1" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.api.id
  path_part   = "v1"
}

resource "aws_api_gateway_resource" "api_v1_receive" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.api_v1.id
  path_part   = "receive"
}

# -----------------------------------------------------------------------------
# Method: POST on /api/v1/receive with AWS_IAM auth
# -----------------------------------------------------------------------------

resource "aws_api_gateway_method" "thanos_receive" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.api_v1_receive.id
  http_method   = "POST"
  authorization = "AWS_IAM"

  request_parameters = {
    "method.request.header.Content-Type"     = false
    "method.request.header.Content-Encoding" = false
  }
}

# -----------------------------------------------------------------------------
# Integration: HTTP (non-proxy) with THANOS-TENANT header injection
#
# CRITICAL: Uses "HTTP" not "HTTP_PROXY". With HTTP integration, API Gateway
# overwrites any client-supplied THANOS-TENANT header with the verified
# account ID from SigV4 validation. This prevents tenant spoofing.
# -----------------------------------------------------------------------------

resource "aws_api_gateway_integration" "thanos_receive" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.api_v1_receive.id
  http_method             = aws_api_gateway_method.thanos_receive.http_method
  type                    = "HTTP"
  integration_http_method = "POST"
  connection_type         = "VPC_LINK"
  connection_id           = aws_apigatewayv2_vpc_link.main.id
  integration_target      = aws_lb.platform.arn
  uri                     = "http://${aws_lb.platform.dns_name}/api/v1/receive"

  request_parameters = {
    "integration.request.header.THANOS-TENANT"    = "context.identity.accountId"
    "integration.request.header.Content-Type"     = "method.request.header.Content-Type"
    "integration.request.header.Content-Encoding" = "method.request.header.Content-Encoding"
  }

  passthrough_behavior = "WHEN_NO_MATCH"
}

# -----------------------------------------------------------------------------
# Method and Integration Responses
#
# Required for HTTP (non-proxy) integrations to return responses to callers.
# -----------------------------------------------------------------------------

resource "aws_api_gateway_method_response" "thanos_receive" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.api_v1_receive.id
  http_method = aws_api_gateway_method.thanos_receive.http_method
  status_code = "200"
}

resource "aws_api_gateway_integration_response" "thanos_receive" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.api_v1_receive.id
  http_method = aws_api_gateway_method.thanos_receive.http_method
  status_code = "200"

  depends_on = [aws_api_gateway_integration.thanos_receive]
}
