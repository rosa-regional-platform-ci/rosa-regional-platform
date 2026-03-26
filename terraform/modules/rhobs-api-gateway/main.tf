# =============================================================================
# RHOBS API Gateway (HTTP API v2)
#
# Separate HTTP API v2 gateway for Thanos Receive metrics ingestion.
# Uses HTTP API v2 because REST API v1 rejects Content-Encoding: snappy
# (used by Prometheus remote_write) with 415 Unsupported Media Type.
#
# HTTP API v2 passes all content through natively without content negotiation.
#
# Flow: MC sigv4-proxy -> HTTP API v2 (SigV4 auth) -> VPC Link -> ALB -> Thanos Receive
# =============================================================================

# -----------------------------------------------------------------------------
# HTTP API
# -----------------------------------------------------------------------------

resource "aws_apigatewayv2_api" "rhobs" {
  name          = "${var.regional_id}-rhobs"
  protocol_type = "HTTP"

  tags = {
    Name = "${var.regional_id}-rhobs"
  }
}

# -----------------------------------------------------------------------------
# Integration: VPC Link to ALB
#
# HTTP_PROXY passes the request through to the ALB as-is.
# THANOS-TENANT header is injected from the verified SigV4 account ID,
# preventing tenant spoofing — callers can only write to their own tenant.
# -----------------------------------------------------------------------------

resource "aws_apigatewayv2_integration" "thanos" {
  api_id             = aws_apigatewayv2_api.rhobs.id
  integration_type   = "HTTP_PROXY"
  integration_method = "POST"
  integration_uri    = var.alb_listener_arn
  connection_type    = "VPC_LINK"
  connection_id      = var.vpc_link_id

  request_parameters = {
    "overwrite:header.THANOS-TENANT" = "$context.identity.accountId"
  }
}

# -----------------------------------------------------------------------------
# Route: POST /api/v1/receive
#
# AWS_IAM authorization requires SigV4-signed requests.
# Any valid AWS account can call (no resource policy), but the
# THANOS-TENANT header injection ensures tenant isolation.
# -----------------------------------------------------------------------------

resource "aws_apigatewayv2_route" "thanos_receive" {
  api_id             = aws_apigatewayv2_api.rhobs.id
  route_key          = "POST /api/v1/receive"
  authorization_type = "AWS_IAM"
  target             = "integrations/${aws_apigatewayv2_integration.thanos.id}"
}

# -----------------------------------------------------------------------------
# Stage: $default (auto-deploy)
#
# HTTP API v2 with auto_deploy eliminates the manual deployment/stage
# dance required by REST API v1.
# -----------------------------------------------------------------------------

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.rhobs.id
  name        = "$default"
  auto_deploy = true

  tags = {
    Name = "${var.regional_id}-rhobs"
  }
}
