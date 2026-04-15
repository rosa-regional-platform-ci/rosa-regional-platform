# =============================================================================
# API Gateway REST API
#
# Creates a REST API with AWS_IAM authentication and a single {proxy+}
# catch-all resource that forwards all requests to the backend.
# =============================================================================

# -----------------------------------------------------------------------------
# Data Sources
# -----------------------------------------------------------------------------

data "aws_region" "current" {}

# -----------------------------------------------------------------------------
# REST API
# -----------------------------------------------------------------------------

resource "aws_api_gateway_rest_api" "main" {
  name        = "${var.regional_id}-api"
  description = var.api_description

  # Binary media types — API GW passes these payloads through as-is
  # without text encoding. Required for Prometheus remote_write (protobuf).
  binary_media_types = ["application/x-protobuf"]

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = {
    Name = "${var.regional_id}-api"
  }
}

# -----------------------------------------------------------------------------
# Proxy Resource: {proxy+}
#
# Catches all paths and forwards them to the backend.
# The backend service handles its own routing.
# -----------------------------------------------------------------------------

resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "{proxy+}"
}

# -----------------------------------------------------------------------------
# Method: ANY on {proxy+}
#
# Accepts all HTTP methods with AWS_IAM authentication.
# Requires SigV4 signed requests (use awscurl for testing).
# -----------------------------------------------------------------------------

resource "aws_api_gateway_method" "proxy" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.proxy.id
  http_method   = "ANY"
  authorization = "AWS_IAM"

  request_parameters = {
    "method.request.path.proxy" = true
  }
}

# -----------------------------------------------------------------------------
# Root Resource Method: ANY on /
#
# Handle requests to the root path (e.g., health checks at /)
# -----------------------------------------------------------------------------

resource "aws_api_gateway_method" "root" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_rest_api.main.root_resource_id
  http_method   = "ANY"
  authorization = "AWS_IAM"
}

# -----------------------------------------------------------------------------
# Deployment and Stage
# -----------------------------------------------------------------------------

resource "aws_api_gateway_deployment" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id

  # Ensure deployment happens after all resources are created
  depends_on = [
    aws_api_gateway_integration.proxy,
    aws_api_gateway_integration.root,
    aws_api_gateway_rest_api_policy.main,
  ]

  # Force new deployment when configuration changes
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.proxy.id,
      aws_api_gateway_method.proxy.id,
      aws_api_gateway_method.root.id,
      aws_api_gateway_integration.proxy.id,
      aws_api_gateway_integration.root.id,
      aws_api_gateway_rest_api_policy.main.policy,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "main" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  deployment_id = aws_api_gateway_deployment.main.id
  stage_name    = var.stage_name

  tags = {
    Name = "${var.regional_id}-api-${var.stage_name}"
  }
}

# -----------------------------------------------------------------------------
# FedRAMP CM-07: Least Functionality — API Gateway Method Settings
#
# Restrict unnecessary capabilities: enable detailed metrics and throttling,
# disable execution logging at the method level to avoid PII in logs, and
# enforce that only necessary methods/capabilities are active.
# -----------------------------------------------------------------------------

resource "aws_api_gateway_method_settings" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  stage_name  = aws_api_gateway_stage.main.stage_name
  method_path = "*/*"

  settings {
    metrics_enabled        = true
    logging_level          = "ERROR"
    data_trace_enabled     = false
    throttling_burst_limit = 500
    throttling_rate_limit  = 100
  }
}
