# =============================================================================
# API Gateway Integrations
#
# HTTP_PROXY integration forwards requests to the internal ALB via VPC Link,
# passing backend status codes through transparently. This ensures Prometheus
# remote_write clients see real 4xx/5xx responses for retry/backoff.
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
  type                    = "HTTP_PROXY"
  integration_http_method = "POST"
  connection_type         = "VPC_LINK"
  connection_id           = aws_apigatewayv2_vpc_link.rhobs.id
  integration_target      = aws_lb.rhobs.arn
  uri                     = "http://${aws_lb.rhobs.dns_name}/api/v1/receive"
}
