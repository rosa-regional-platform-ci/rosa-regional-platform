# =============================================================================
# Grafana CloudWatch Logs - IAM Roles and Policies
# =============================================================================

# -----------------------------------------------------------------------------
# Primary mode: IAM role + Pod Identity for Grafana on Regional Cluster
# -----------------------------------------------------------------------------

resource "aws_iam_role" "grafana_primary" {
  count = var.mode == "primary" ? 1 : 0

  name        = "${var.regional_id}-grafana-cw-logs"
  description = "IAM role for Grafana to read CloudWatch Logs (Pod Identity)"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }]
  })

  tags = merge(local.common_tags, {
    Name = "${var.regional_id}-grafana-cw-logs"
  })
}

resource "aws_iam_role_policy" "grafana_logs_read" {
  count = var.mode == "primary" ? 1 : 0

  name = "${var.regional_id}-grafana-cw-logs-read"
  role = aws_iam_role.grafana_primary[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogsRead"
        Effect = "Allow"
        Action = [
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
          "logs:GetLogEvents",
          "logs:FilterLogEvents",
          "logs:StartQuery",
          "logs:StopQuery",
          "logs:GetQueryResults",
          "logs:GetLogRecord",
          "logs:GetLogGroupFields",
        ]
        Resource = "*"
      },
      {
        Sid    = "CloudWatchMetricsListForDatasourceTest"
        Effect = "Allow"
        Action = [
          "cloudwatch:ListMetrics",
        ]
        Resource = "*"
      },
      {
        Sid    = "AssumeManagementClusterReaderRoles"
        Effect = "Allow"
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
        Resource = "arn:aws:iam::*:role/*-grafana-cw-logs-reader"
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "grafana" {
  count = var.mode == "primary" ? 1 : 0

  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = var.service_account
  role_arn        = aws_iam_role.grafana_primary[0].arn

  tags = merge(local.common_tags, {
    Name = "${var.regional_id}-grafana-cw-logs-pod-identity"
  })
}

# -----------------------------------------------------------------------------
# Reader mode: Cross-account role for MC, trusting the RC Grafana role
# -----------------------------------------------------------------------------

resource "aws_iam_role" "grafana_reader" {
  count = var.mode == "reader" ? 1 : 0

  name        = "${var.regional_id}-grafana-cw-logs-reader"
  description = "Cross-account reader role for RC Grafana to query MC CloudWatch Logs"

  lifecycle {
    precondition {
      condition     = var.grafana_role_account_id != ""
      error_message = "grafana_role_account_id is required when mode is 'reader'"
    }
  }

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        AWS = "arn:aws:iam::${var.grafana_role_account_id}:root"
      }
      Action = [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
      Condition = {
        StringLike = {
          "aws:PrincipalArn" = "arn:aws:iam::${var.grafana_role_account_id}:role/*-grafana-cw-logs"
        }
      }
    }]
  })

  tags = merge(local.common_tags, {
    Name = "${var.regional_id}-grafana-cw-logs-reader"
  })
}

resource "aws_iam_role_policy" "grafana_reader_logs" {
  count = var.mode == "reader" ? 1 : 0

  name = "${var.regional_id}-grafana-cw-logs-reader"
  role = aws_iam_role.grafana_reader[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogsRead"
        Effect = "Allow"
        Action = [
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
          "logs:GetLogEvents",
          "logs:FilterLogEvents",
          "logs:StartQuery",
          "logs:StopQuery",
          "logs:GetQueryResults",
          "logs:GetLogRecord",
          "logs:GetLogGroupFields",
        ]
        Resource = "*"
      },
      {
        Sid    = "CloudWatchMetricsListForDatasourceTest"
        Effect = "Allow"
        Action = [
          "cloudwatch:ListMetrics",
        ]
        Resource = "*"
      }
    ]
  })
}
