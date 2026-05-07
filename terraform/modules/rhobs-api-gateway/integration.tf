# =============================================================================
# API Gateway Integrations
#
# Each backend (Thanos Receive, Thanos Query, Loki) gets its own method +
# integration pair. Uses HTTP (non-proxy) so API Gateway controls which
# headers reach the backend.
# =============================================================================

# -----------------------------------------------------------------------------
# Thanos Receive: POST /api/v1/receive
#
# Accepts Prometheus remote_write payloads from Management Clusters.
# No tenant header is injected — Thanos Receive stores all metrics under its
# default tenant, and cluster identity is carried by metric labels.
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

resource "aws_api_gateway_integration" "thanos_receive" {
  rest_api_id             = aws_api_gateway_rest_api.rhobs.id
  resource_id             = aws_api_gateway_resource.api_v1_receive.id
  http_method             = aws_api_gateway_method.thanos_receive.http_method
  type                    = "HTTP"
  integration_http_method = "POST"
  connection_type         = "VPC_LINK"
  connection_id           = aws_apigatewayv2_vpc_link.rhobs.id
  integration_target      = aws_lb.rhobs.arn
  uri                     = "http://${aws_lb.rhobs.dns_name}/api/v1/receive"

  request_parameters = {
    "integration.request.header.Content-Type"     = "method.request.header.Content-Type"
    "integration.request.header.Content-Encoding" = "method.request.header.Content-Encoding"
  }

  passthrough_behavior = "WHEN_NO_MATCH"
}

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
