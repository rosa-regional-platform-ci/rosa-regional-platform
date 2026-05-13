# =============================================================================
# RHOBS API Gateway
#
# Dedicated REST API for RHOBS (observability) traffic. Includes its own ALB,
# VPC Link, and security groups — fully isolated from the Platform API Gateway.
# Only MC accounts can invoke this API via resource policy.
#
# Flow: POST /api/v1/receive -> VPC Link -> RHOBS ALB -> Thanos Receive (:19291)
#       GET  /api/v1/query   -> VPC Link -> RHOBS ALB -> Thanos Query Frontend (:9090)
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
  name        = "${var.regional_id}-rhobs"
  description = "RHOBS metrics ingestion API (Thanos Receive)"

  # Binary media types — API GW passes these payloads through as-is
  # without text encoding. Required for Prometheus remote_write (protobuf).
  binary_media_types = ["application/x-protobuf"]

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = {
    Name = "${var.regional_id}-rhobs"
  }
}

# -----------------------------------------------------------------------------
# Resource chain: /api -> /api/v1 -> /api/v1/receive
#                                  -> /api/v1/query
#                                  -> /api/v1/query_range
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

resource "aws_api_gateway_resource" "api_v1_query" {
  rest_api_id = aws_api_gateway_rest_api.rhobs.id
  parent_id   = aws_api_gateway_resource.api_v1.id
  path_part   = "query"
}

resource "aws_api_gateway_resource" "api_v1_query_range" {
  rest_api_id = aws_api_gateway_rest_api.rhobs.id
  parent_id   = aws_api_gateway_resource.api_v1.id
  path_part   = "query_range"
}

# -----------------------------------------------------------------------------
# Deployment and Stage
# -----------------------------------------------------------------------------

resource "aws_api_gateway_deployment" "rhobs" {
  rest_api_id = aws_api_gateway_rest_api.rhobs.id

  depends_on = [
    aws_api_gateway_integration.thanos_receive,
    aws_api_gateway_integration.thanos_query,
    aws_api_gateway_integration.thanos_query_range,
    aws_api_gateway_rest_api_policy.rhobs,
  ]

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.api_v1_receive.id,
      aws_api_gateway_method.thanos_receive.id,
      aws_api_gateway_integration.thanos_receive.id,
      aws_api_gateway_rest_api.rhobs.binary_media_types,
      aws_api_gateway_rest_api_policy.rhobs.policy,
      aws_api_gateway_resource.api_v1_query.id,
      aws_api_gateway_method.thanos_query.id,
      aws_api_gateway_integration.thanos_query.id,
      aws_api_gateway_resource.api_v1_query_range.id,
      aws_api_gateway_method.thanos_query_range.id,
      aws_api_gateway_integration.thanos_query_range.id,
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
    Name = "${var.regional_id}-rhobs-${var.stage_name}"
  }
}

# -----------------------------------------------------------------------------
# Method Settings
#
# Enable CloudWatch metrics (Count, Latency, 4XX/5XX) for the API Gateway.
# No execution logging — internal M2M traffic with known request patterns.
# -----------------------------------------------------------------------------

resource "aws_api_gateway_method_settings" "rhobs" {
  rest_api_id = aws_api_gateway_rest_api.rhobs.id
  stage_name  = aws_api_gateway_stage.rhobs.stage_name
  method_path = "*/*"

  settings {
    metrics_enabled = var.metrics_enabled
  }
}
