# ECS Fargate Bastion Module
# Provides ephemeral break-glass access to private EKS clusters via ECS Exec (SSM)
# and a log-collector task for gathering kubernetes logs via oc adm inspect.

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
