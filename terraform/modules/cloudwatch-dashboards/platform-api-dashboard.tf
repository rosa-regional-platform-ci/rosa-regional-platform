# =============================================================================
# Platform API Gateway Dashboard
#
# Detailed drilldown dashboard for the Platform API Gateway, showing
# request volume, error rates, and latency distributions.
# =============================================================================

resource "aws_cloudwatch_dashboard" "platform_api" {
  dashboard_name = "${var.regional_id}-platform-api"

  dashboard_body = jsonencode({
    widgets = [
      # -----------------------------------------------------------------------
      # Row 1: Request Volume and Error Rates
      # -----------------------------------------------------------------------
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Request Count"
          region = data.aws_region.current.name
          period = var.dashboard_period
          stat   = "Sum"
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiId", var.platform_api_gateway_id, "Stage", var.platform_api_stage_name],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Error Rates"
          region = data.aws_region.current.name
          period = var.dashboard_period
          stat   = "Sum"
          metrics = [
            ["AWS/ApiGateway", "4XXError", "ApiId", var.platform_api_gateway_id, "Stage", var.platform_api_stage_name],
            [".", "5XXError", ".", ".", ".", "."],
          ]
        }
      },

      # -----------------------------------------------------------------------
      # Row 2: Latency
      # -----------------------------------------------------------------------
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Latency (p50 / p90 / p99)"
          region = data.aws_region.current.name
          period = var.dashboard_period
          metrics = [
            ["AWS/ApiGateway", "Latency", "ApiId", var.platform_api_gateway_id, "Stage", var.platform_api_stage_name, { stat = "p50", label = "p50" }],
            ["...", { stat = "p90", label = "p90" }],
            ["...", { stat = "p99", label = "p99" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Integration Latency (p50 / p90 / p99)"
          region = data.aws_region.current.name
          period = var.dashboard_period
          metrics = [
            ["AWS/ApiGateway", "IntegrationLatency", "ApiId", var.platform_api_gateway_id, "Stage", var.platform_api_stage_name, { stat = "p50", label = "p50" }],
            ["...", { stat = "p90", label = "p90" }],
            ["...", { stat = "p99", label = "p99" }],
          ]
        }
      },

      # -----------------------------------------------------------------------
      # Row 3: Cache Performance (if caching is enabled)
      # -----------------------------------------------------------------------
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "Cache Hit / Miss"
          region = data.aws_region.current.name
          period = var.dashboard_period
          stat   = "Sum"
          metrics = [
            ["AWS/ApiGateway", "CacheHitCount", "ApiId", var.platform_api_gateway_id, "Stage", var.platform_api_stage_name],
            [".", "CacheMissCount", ".", ".", ".", "."],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "Error Rate (%)"
          region = data.aws_region.current.name
          period = var.dashboard_period
          view   = "timeSeries"
          metrics = [
            [{ expression = "100 * m1 / m3", label = "4XX %", id = "e1" }],
            [{ expression = "100 * m2 / m3", label = "5XX %", id = "e2" }],
            ["AWS/ApiGateway", "4XXError", "ApiId", var.platform_api_gateway_id, "Stage", var.platform_api_stage_name, { stat = "Sum", id = "m1", visible = false }],
            [".", "5XXError", ".", ".", ".", ".", { stat = "Sum", id = "m2", visible = false }],
            [".", "Count", ".", ".", ".", ".", { stat = "Sum", id = "m3", visible = false }],
          ]
        }
      },
    ]
  })
}
