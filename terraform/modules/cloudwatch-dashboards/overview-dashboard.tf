# =============================================================================
# Account Health Overview Dashboard
#
# High-level operational health across all core services:
# - API Gateway (summary — drilldowns in per-API dashboards)
# - AWS IoT Core (Maestro MQTT)
# - RDS (Maestro + HyperFleet databases)
# - EKS (Regional Cluster control plane)
# =============================================================================

data "aws_region" "current" {}

resource "aws_cloudwatch_dashboard" "overview" {
  dashboard_name = "${var.regional_id}-overview"

  dashboard_body = jsonencode({
    widgets = flatten([
      # =====================================================================
      # API Gateway Summary
      # =====================================================================
      [
        {
          type   = "text"
          x      = 0
          y      = 0
          width  = 24
          height = 1
          properties = {
            markdown = "## API Gateway"
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = 1
          width  = 8
          height = 6
          properties = {
            title  = "Total Requests"
            region = data.aws_region.current.name
            period = var.dashboard_period
            stat   = "Sum"
            metrics = [
              ["AWS/ApiGateway", "Count", "ApiId", var.platform_api_gateway_id, "Stage", var.platform_api_stage_name, { label = "Platform API" }],
              [".", ".", ".", var.rhobs_api_gateway_id, ".", var.rhobs_api_stage_name, { label = "RHOBS API" }],
            ]
          }
        },
        {
          type   = "metric"
          x      = 8
          y      = 1
          width  = 8
          height = 6
          properties = {
            title  = "5XX Errors"
            region = data.aws_region.current.name
            period = var.dashboard_period
            stat   = "Sum"
            metrics = [
              ["AWS/ApiGateway", "5XXError", "ApiId", var.platform_api_gateway_id, "Stage", var.platform_api_stage_name, { label = "Platform API" }],
              [".", ".", ".", var.rhobs_api_gateway_id, ".", var.rhobs_api_stage_name, { label = "RHOBS API" }],
            ]
          }
        },
        {
          type   = "metric"
          x      = 16
          y      = 1
          width  = 8
          height = 6
          properties = {
            title  = "Latency p99"
            region = data.aws_region.current.name
            period = var.dashboard_period
            stat   = "p99"
            metrics = [
              ["AWS/ApiGateway", "Latency", "ApiId", var.platform_api_gateway_id, "Stage", var.platform_api_stage_name, { label = "Platform API" }],
              [".", ".", ".", var.rhobs_api_gateway_id, ".", var.rhobs_api_stage_name, { label = "RHOBS API" }],
            ]
          }
        },
      ],

      # =====================================================================
      # AWS IoT Core (Maestro MQTT)
      # =====================================================================
      [
        {
          type   = "text"
          x      = 0
          y      = 7
          width  = 24
          height = 1
          properties = {
            markdown = "## AWS IoT Core"
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = 8
          width  = 8
          height = 6
          properties = {
            title  = "MQTT Connections"
            region = data.aws_region.current.name
            period = var.dashboard_period
            stat   = "Sum"
            metrics = [
              ["AWS/IoT", "Connect.Success", { label = "Successful" }],
              [".", "Connect.AuthError", { label = "Auth Errors" }],
            ]
          }
        },
        {
          type   = "metric"
          x      = 8
          y      = 8
          width  = 8
          height = 6
          properties = {
            title  = "MQTT Messages"
            region = data.aws_region.current.name
            period = var.dashboard_period
            stat   = "Sum"
            metrics = [
              ["AWS/IoT", "PublishIn.Success", { label = "Published In" }],
              [".", "PublishOut.Success", { label = "Published Out" }],
              [".", "Subscribe.Success", { label = "Subscriptions" }],
            ]
          }
        },
        {
          type   = "metric"
          x      = 16
          y      = 8
          width  = 8
          height = 6
          properties = {
            title  = "MQTT Errors"
            region = data.aws_region.current.name
            period = var.dashboard_period
            stat   = "Sum"
            metrics = [
              ["AWS/IoT", "PublishIn.ServerError", { label = "Publish Server Errors" }],
              [".", "PublishIn.Throttle", { label = "Publish Throttles" }],
              [".", "Connect.Throttle", { label = "Connect Throttles" }],
            ]
          }
        },
      ],

      # =====================================================================
      # RDS (Maestro + HyperFleet)
      # =====================================================================
      [
        {
          type   = "text"
          x      = 0
          y      = 14
          width  = 24
          height = 1
          properties = {
            markdown = "## RDS"
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = 15
          width  = 8
          height = 6
          properties = {
            title  = "CPU Utilization (%)"
            region = data.aws_region.current.name
            period = var.dashboard_period
            stat   = "Average"
            metrics = [
              ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", var.maestro_rds_identifier, { label = "Maestro" }],
              [".", ".", ".", var.hyperfleet_rds_identifier, { label = "HyperFleet" }],
            ]
          }
        },
        {
          type   = "metric"
          x      = 8
          y      = 15
          width  = 8
          height = 6
          properties = {
            title  = "Database Connections"
            region = data.aws_region.current.name
            period = var.dashboard_period
            stat   = "Average"
            metrics = [
              ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", var.maestro_rds_identifier, { label = "Maestro" }],
              [".", ".", ".", var.hyperfleet_rds_identifier, { label = "HyperFleet" }],
            ]
          }
        },
        {
          type   = "metric"
          x      = 16
          y      = 15
          width  = 8
          height = 6
          properties = {
            title  = "Free Storage Space"
            region = data.aws_region.current.name
            period = var.dashboard_period
            stat   = "Average"
            metrics = [
              ["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", var.maestro_rds_identifier, { label = "Maestro" }],
              [".", ".", ".", var.hyperfleet_rds_identifier, { label = "HyperFleet" }],
            ]
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = 21
          width  = 8
          height = 6
          properties = {
            title  = "Read / Write IOPS"
            region = data.aws_region.current.name
            period = var.dashboard_period
            stat   = "Average"
            metrics = [
              ["AWS/RDS", "ReadIOPS", "DBInstanceIdentifier", var.maestro_rds_identifier, { label = "Maestro Read" }],
              [".", "WriteIOPS", ".", ".", { label = "Maestro Write" }],
              [".", "ReadIOPS", ".", var.hyperfleet_rds_identifier, { label = "HyperFleet Read" }],
              [".", "WriteIOPS", ".", ".", { label = "HyperFleet Write" }],
            ]
          }
        },
        {
          type   = "metric"
          x      = 8
          y      = 21
          width  = 8
          height = 6
          properties = {
            title  = "Read / Write Latency"
            region = data.aws_region.current.name
            period = var.dashboard_period
            stat   = "Average"
            metrics = [
              ["AWS/RDS", "ReadLatency", "DBInstanceIdentifier", var.maestro_rds_identifier, { label = "Maestro Read" }],
              [".", "WriteLatency", ".", ".", { label = "Maestro Write" }],
              [".", "ReadLatency", ".", var.hyperfleet_rds_identifier, { label = "HyperFleet Read" }],
              [".", "WriteLatency", ".", ".", { label = "HyperFleet Write" }],
            ]
          }
        },
        {
          type   = "metric"
          x      = 16
          y      = 21
          width  = 8
          height = 6
          properties = {
            title  = "Freeable Memory"
            region = data.aws_region.current.name
            period = var.dashboard_period
            stat   = "Average"
            metrics = [
              ["AWS/RDS", "FreeableMemory", "DBInstanceIdentifier", var.maestro_rds_identifier, { label = "Maestro" }],
              [".", ".", ".", var.hyperfleet_rds_identifier, { label = "HyperFleet" }],
            ]
          }
        },
      ],

      # =====================================================================
      # EKS (Regional Cluster Control Plane)
      # =====================================================================
      [
        {
          type   = "text"
          x      = 0
          y      = 27
          width  = 24
          height = 1
          properties = {
            markdown = "## EKS"
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = 28
          width  = 8
          height = 6
          properties = {
            title  = "API Server Requests"
            region = data.aws_region.current.name
            period = var.dashboard_period
            stat   = "Sum"
            metrics = [
              ["AWS/EKS", "apiserver_request_total", "ClusterName", var.eks_cluster_name],
              [".", "apiserver_request_total_4XX", ".", "."],
              [".", "apiserver_request_total_5XX", ".", "."],
            ]
          }
        },
        {
          type   = "metric"
          x      = 8
          y      = 28
          width  = 8
          height = 6
          properties = {
            title  = "API Server Latency p99"
            region = data.aws_region.current.name
            period = var.dashboard_period
            stat   = "Average"
            metrics = [
              ["AWS/EKS", "apiserver_request_duration_seconds_GET_P99", "ClusterName", var.eks_cluster_name, { label = "GET" }],
              [".", "apiserver_request_duration_seconds_LIST_P99", ".", ".", { label = "LIST" }],
              [".", "apiserver_request_duration_seconds_POST_P99", ".", ".", { label = "POST" }],
              [".", "apiserver_request_duration_seconds_PUT_P99", ".", ".", { label = "PUT" }],
            ]
          }
        },
        {
          type   = "metric"
          x      = 16
          y      = 28
          width  = 8
          height = 6
          properties = {
            title  = "etcd DB Size"
            region = data.aws_region.current.name
            period = var.dashboard_period
            stat   = "Average"
            metrics = [
              ["AWS/EKS", "apiserver_storage_size_bytes", "ClusterName", var.eks_cluster_name, { label = "Storage Size" }],
              [".", "etcd_mvcc_db_total_size_in_use_in_bytes", ".", ".", { label = "DB In-Use Size" }],
            ]
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = 34
          width  = 8
          height = 6
          properties = {
            title  = "Scheduler"
            region = data.aws_region.current.name
            period = var.dashboard_period
            stat   = "Sum"
            metrics = [
              ["AWS/EKS", "scheduler_schedule_attempts_total", "ClusterName", var.eks_cluster_name, { label = "Total Attempts" }],
              [".", "scheduler_schedule_attempts_SCHEDULED", ".", ".", { label = "Scheduled" }],
              [".", "scheduler_schedule_attempts_UNSCHEDULABLE", ".", ".", { label = "Unschedulable" }],
              [".", "scheduler_schedule_attempts_ERROR", ".", ".", { label = "Errors" }],
            ]
          }
        },
        {
          type   = "metric"
          x      = 8
          y      = 34
          width  = 8
          height = 6
          properties = {
            title  = "Pending Pods"
            region = data.aws_region.current.name
            period = var.dashboard_period
            stat   = "Average"
            metrics = [
              ["AWS/EKS", "scheduler_pending_pods", "ClusterName", var.eks_cluster_name, { label = "Total" }],
              [".", "scheduler_pending_pods_ACTIVEQ", ".", ".", { label = "ActiveQ" }],
              [".", "scheduler_pending_pods_BACKOFF", ".", ".", { label = "Backoff" }],
              [".", "scheduler_pending_pods_UNSCHEDULABLE", ".", ".", { label = "Unschedulable" }],
              [".", "scheduler_pending_pods_GATED", ".", ".", { label = "Gated" }],
            ]
          }
        },
        {
          type   = "metric"
          x      = 16
          y      = 34
          width  = 8
          height = 6
          properties = {
            title  = "Inflight Requests"
            region = data.aws_region.current.name
            period = var.dashboard_period
            stat   = "Average"
            metrics = [
              ["AWS/EKS", "apiserver_current_inflight_requests_READONLY", "ClusterName", var.eks_cluster_name, { label = "Read-Only" }],
              [".", "apiserver_current_inflight_requests_MUTATING", ".", ".", { label = "Mutating" }],
              [".", "apiserver_flowcontrol_current_executing_seats", ".", ".", { label = "Executing Seats" }],
            ]
          }
        },
      ],
    ])
  })
}
