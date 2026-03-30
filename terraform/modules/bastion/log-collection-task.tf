# Log Collector ECS task — runs oc adm inspect for specified namespaces,
# tars the output, uploads to S3, and exits. The calling script polls for
# task completion, then downloads from S3.

# =============================================================================
# S3 Bucket for Log Transfer
# =============================================================================
# Used by the log-collector task to upload oc adm inspect output.
# Objects expire after 1 day to avoid accumulating stale data.

resource "aws_s3_bucket" "logs_transfer" {
  bucket        = "${var.cluster_id}-bastion-logs-${local.account_id}"
  force_destroy = true

  tags = var.tags
}

resource "aws_s3_bucket_lifecycle_configuration" "logs_transfer" {
  bucket = aws_s3_bucket.logs_transfer.id

  rule {
    id     = "expire-logs"
    status = "Enabled"

    expiration {
      days = 1
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_s3_bucket_public_access_block" "logs_transfer" {
  bucket = aws_s3_bucket.logs_transfer.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# =============================================================================
# Task Definition
# =============================================================================
# Namespaces and S3 key are passed as environment variable overrides at run time.

resource "aws_ecs_task_definition" "log_collector" {
  family                   = "${var.cluster_id}-log-collector"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.log_collector.arn

  container_definitions = jsonencode([
    {
      name      = "log-collector"
      image     = var.container_image
      essential = true

      entryPoint = ["/bin/bash", "-c"]
      command = [
        <<-EOF
          set -euo pipefail

          echo "=== Log Collector ==="
          echo "Cluster:    $CLUSTER_NAME"
          echo "Namespaces: $INSPECT_NAMESPACES"
          echo "S3 dest:    s3://$S3_BUCKET/$S3_KEY"
          echo ""

          # Configure kubectl
          aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"

          # Run oc adm inspect
          echo "Running oc adm inspect..."
          # shellcheck disable=SC2086
          oc adm inspect $INSPECT_NAMESPACES --dest-dir=/tmp/inspect-logs || true

          # Tar and upload to S3
          echo "Uploading to S3..."
          tar czf /tmp/inspect-logs.tar.gz -C /tmp inspect-logs
          aws s3 cp /tmp/inspect-logs.tar.gz "s3://$S3_BUCKET/$S3_KEY"

          echo "Done."
        EOF
      ]

      environment = [
        {
          name  = "CLUSTER_NAME"
          value = var.cluster_name
        },
        {
          name  = "AWS_REGION"
          value = data.aws_region.current.id
        },
        {
          name  = "S3_BUCKET"
          value = aws_s3_bucket.logs_transfer.id
        },
        {
          name  = "INSPECT_NAMESPACES"
          value = "ns/default"
        },
        {
          name  = "S3_KEY"
          value = "inspect-logs.tar.gz"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.bastion.name
          awslogs-region        = data.aws_region.current.id
          awslogs-stream-prefix = "log-collector"
        }
      }
    }
  ])

  tags = var.tags
}

# =============================================================================
# Task Role — EKS access + S3 upload
# =============================================================================

resource "aws_iam_role" "log_collector" {
  name = "${var.cluster_id}-log-collector"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "log_collector_eks" {
  name = "eks-access"
  role = aws_iam_role.log_collector.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EKSListClusters"
        Effect = "Allow"
        Action = [
          "eks:ListClusters"
        ]
        Resource = "*"
      },
      {
        Sid    = "EKSClusterAccess"
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:AccessKubernetesApi"
        ]
        Resource = "arn:aws:eks:${data.aws_region.current.id}:${local.account_id}:cluster/${var.cluster_name}"
      }
    ]
  })
}

resource "aws_iam_role_policy" "log_collector_s3" {
  name = "s3-logs-upload"
  role = aws_iam_role.log_collector.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3Upload"
        Effect = "Allow"
        Action = [
          "s3:PutObject"
        ]
        Resource = "${aws_s3_bucket.logs_transfer.arn}/*"
      }
    ]
  })
}

# =============================================================================
# EKS Access — Grants the log-collector task role cluster admin access
# =============================================================================

resource "aws_eks_access_entry" "log_collector" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.log_collector.arn
  type          = "STANDARD"

  tags = var.tags
}

resource "aws_eks_access_policy_association" "log_collector" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.log_collector.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminViewPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.log_collector]
}
