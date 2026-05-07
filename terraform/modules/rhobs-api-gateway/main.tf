# =============================================================================
# RHOBS API Gateway
#
# Dedicated REST API for RHOBS (observability) traffic. Includes its own ALB,
# VPC Link, and security groups — fully isolated from the Platform API Gateway.
# Only MC accounts can invoke this API via resource policy.
#
# Flow: POST /api/v1/receive -> VPC Link -> RHOBS ALB -> Thanos Receive (:19291)
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
      aws_api_gateway_rest_api_policy.rhobs.policy,
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
