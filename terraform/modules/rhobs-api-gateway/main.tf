# =============================================================================
# RHOBS API Gateway
#
# Dedicated REST API v1 for metrics ingestion (Prometheus remote_write).
# Separate from the Platform API Gateway to enforce independent access control:
# only MC accounts can invoke this API via resource policy.
#
# Flow: POST /api/v1/receive -> VPC Link -> ALB -> Thanos Receive (:19291)
# =============================================================================

# -----------------------------------------------------------------------------
# Data Sources
# -----------------------------------------------------------------------------

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------
# REST API
# -----------------------------------------------------------------------------

resource "aws_api_gateway_rest_api" "rhobs" {
  name        = "${var.regional_id}-rhobs-api"
  description = "RHOBS metrics ingestion API (Thanos Receive)"

  # Binary media types — API GW passes these payloads through as-is
  # without text encoding. Required for Prometheus remote_write (protobuf).
  binary_media_types = ["application/x-protobuf"]

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = {
    Name = "${var.regional_id}-rhobs-api"
  }
}

# -----------------------------------------------------------------------------
# Resource chain: /api -> /api/v1 -> /api/v1/receive
# -----------------------------------------------------------------------------

resource "aws_api_gateway_resource" "api" {
  rest_api_id = aws_api_gateway_rest_api.rhobs.id
  parent_id   = aws_api_gateway_rest_api.rhobs.root_resource_id
  path_part   = "api"
}

resource "aws_api_gateway_resource" "api_v1" {
  rest_api_id = aws_api_gateway_rest_api.rhobs.id
  parent_id   = aws_api_gateway_resource.api.id
  path_part   = "v1"
}

resource "aws_api_gateway_resource" "api_v1_receive" {
  rest_api_id = aws_api_gateway_rest_api.rhobs.id
  parent_id   = aws_api_gateway_resource.api_v1.id
  path_part   = "receive"
}

# -----------------------------------------------------------------------------
# Method: POST on /api/v1/receive with AWS_IAM auth
# -----------------------------------------------------------------------------

resource "aws_api_gateway_method" "thanos_receive" {
  rest_api_id   = aws_api_gateway_rest_api.rhobs.id
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
  rest_api_id             = aws_api_gateway_rest_api.rhobs.id
  resource_id             = aws_api_gateway_resource.api_v1_receive.id
  http_method             = aws_api_gateway_method.thanos_receive.http_method
  type                    = "HTTP"
  integration_http_method = "POST"
  connection_type         = "VPC_LINK"
  connection_id           = var.vpc_link_id
  integration_target      = var.alb_arn
  uri                     = "http://${var.alb_dns_name}/api/v1/receive"

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
  rest_api_id = aws_api_gateway_rest_api.rhobs.id
  resource_id = aws_api_gateway_resource.api_v1_receive.id
  http_method = aws_api_gateway_method.thanos_receive.http_method
  status_code = "200"
}

resource "aws_api_gateway_integration_response" "thanos_receive" {
  rest_api_id = aws_api_gateway_rest_api.rhobs.id
  resource_id = aws_api_gateway_resource.api_v1_receive.id
  http_method = aws_api_gateway_method.thanos_receive.http_method
  status_code = "200"

  depends_on = [aws_api_gateway_integration.thanos_receive]
}

# -----------------------------------------------------------------------------
# Deployment and Stage
# -----------------------------------------------------------------------------

resource "aws_api_gateway_deployment" "rhobs" {
  rest_api_id = aws_api_gateway_rest_api.rhobs.id

  depends_on = [
    aws_api_gateway_integration.thanos_receive,
    aws_api_gateway_rest_api_policy.rhobs,
  ]

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.api_v1_receive.id,
      aws_api_gateway_method.thanos_receive.id,
      aws_api_gateway_integration.thanos_receive.id,
      aws_api_gateway_rest_api.rhobs.binary_media_types,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "rhobs" {
  rest_api_id   = aws_api_gateway_rest_api.rhobs.id
  deployment_id = aws_api_gateway_deployment.rhobs.id
  stage_name    = var.stage_name

  tags = {
    Name = "${var.regional_id}-rhobs-api-${var.stage_name}"
  }
}
