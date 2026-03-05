# ECS Fargate Bastion Module
# Provides ephemeral break-glass access to private EKS clusters via ECS Exec (SSM)

locals {
  container_name = "bastion"
}

data "aws_region" "current" {}

# =============================================================================
# CloudWatch Log Group
# =============================================================================

resource "aws_cloudwatch_log_group" "bastion" {
  name              = "/ecs/${var.cluster_id}/bastion"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

# =============================================================================
# Security Group
# =============================================================================

resource "aws_security_group" "bastion" {
  name        = "${var.cluster_id}-bastion"
  description = "Security group for bastion ECS tasks"
  vpc_id      = var.vpc_id

  # Allow all outbound traffic (needed for tool downloads, EKS API, SSM endpoints)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_id}-bastion"
  })
}

# Allow bastion to access EKS control plane
resource "aws_security_group_rule" "eks_ingress_from_bastion" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = var.cluster_security_group_id
  source_security_group_id = aws_security_group.bastion.id
  description              = "Allow bastion tasks to access EKS API"
}

# =============================================================================
# ECS Cluster (dedicated for bastion tasks)
# =============================================================================

resource "aws_ecs_cluster" "bastion" {
  name = "${var.cluster_id}-bastion"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  # Enable ECS Exec logging
  configuration {
    execute_command_configuration {
      logging = "OVERRIDE"

      log_configuration {
        cloud_watch_log_group_name = aws_cloudwatch_log_group.bastion.name
      }
    }
  }

  tags = var.tags
}

# =============================================================================
# Cleanup Running Tasks on Destroy
# =============================================================================
# This ensures any running bastion tasks are stopped before the cluster is destroyed.
# Without this, terraform destroy would fail if a task was left running.

resource "null_resource" "stop_bastion_tasks" {
  depends_on = [aws_ecs_cluster.bastion]

  triggers = {
    cluster_name = aws_ecs_cluster.bastion.name
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOF
      echo "Stopping any running tasks in ECS cluster ${self.triggers.cluster_name}..."
      TASKS=$(aws ecs list-tasks --cluster ${self.triggers.cluster_name} --query 'taskArns[]' --output text 2>/dev/null || true)
      if [ -n "$TASKS" ] && [ "$TASKS" != "None" ]; then
        for TASK in $TASKS; do
          echo "Stopping task: $TASK"
          aws ecs stop-task --cluster ${self.triggers.cluster_name} --task $TASK --reason "Terraform destroy" || true
        done
        echo "Waiting for tasks to stop..."
        sleep 5
      else
        echo "No running tasks found"
      fi
    EOF
  }
}

# =============================================================================
# ECS Task Definition
# =============================================================================

resource "aws_ecs_task_definition" "bastion" {
  family                   = "${var.cluster_id}-bastion"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = local.container_name
      image     = var.container_image
      essential = true

      # Entrypoint configures kubectl and waits for connections
      # All tools are pre-installed in the container image
      entryPoint = ["/bin/bash", "-c"]
      command = [
        <<-EOF
          set -euo pipefail

          echo "=== ROSA Regional Platform Bastion ==="
          echo "Starting at $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
          echo ""

          echo "Pre-installed tools:"
          echo "  - aws: $(aws --version 2>&1 | head -1)"
          echo "  - kubectl: $(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion')"
          echo "  - helm: $(helm version --short)"
          echo "  - k9s: $(k9s version -s | head -1)"
          echo "  - stern: $(stern --version)"
          echo "  - yq: $(yq --version)"
          echo "  - oc: $(oc version --client -o json 2>/dev/null | jq -r '.releaseClientVersion')"
          echo "  - jq: $(jq --version)"
          echo ""

          # Configure kubectl for EKS
          echo "Configuring kubectl for cluster: $CLUSTER_NAME"
          aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"

          # Verify connectivity
          echo ""
          echo "Testing cluster connectivity..."
          if kubectl cluster-info 2>/dev/null; then
            echo ""
            echo "=== Bastion ready for connections ==="
            echo ""
            echo "Connect using:"
            echo "  aws ecs execute-command \\"
            echo "    --cluster ${var.cluster_id}-bastion \\"
            echo "    --task <TASK_ID> \\"
            echo "    --container bastion \\"
            echo "    --interactive \\"
            echo "    --command '/bin/bash'"
            echo ""
          else
            echo "WARNING: Could not connect to cluster API"
          fi

          # Keep container running for ECS Exec sessions
          echo "Bastion is ready. Waiting for ECS Exec connections..."
          echo "Container will stay running until the task is stopped."
          echo ""

          # Infinite wait - container stays alive for exec sessions
          while true; do
            sleep 3600
          done
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
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.bastion.name
          awslogs-region        = data.aws_region.current.id
          awslogs-stream-prefix = "bastion"
        }
      }

      # Required for ECS Exec
      linuxParameters = {
        initProcessEnabled = true
      }
    }
  ])

  tags = var.tags
}
