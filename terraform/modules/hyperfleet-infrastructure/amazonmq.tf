# =============================================================================
# Amazon MQ for RabbitMQ
#
# Message broker for HyperFleet Sentinel (publisher) and Adapter (consumer).
#
# Security group ingress rules are separate resources so the broker can
# start provisioning before EKS is fully ready. The broker just needs
# to be in its security group; who can connect is defined independently.
# =============================================================================

# Generate secure random password for broker
resource "random_password" "mq_password" {
  length  = 32
  special = true
  # Amazon MQ prohibits: comma (,), colon (:), equals (=), square brackets ([])
  override_special = "!#$%&*()-_+{}?"
}

# Security Group for Amazon MQ - created with egress only (no inline ingress)
resource "aws_security_group" "hyperfleet_mq" {
  name        = "${var.regional_id}-hyperfleet-mq"
  description = "Security group for HyperFleet Amazon MQ broker"
  vpc_id      = var.vpc_id

  revoke_rules_on_delete = false

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.regional_id}-hyperfleet-mq-sg"
      Component = "hyperfleet-sentinel"
    }
  )
}

# Ingress rule: AMQPS from EKS cluster additional security group
# This SG comes from the VPC module and is available immediately
resource "aws_security_group_rule" "hyperfleet_mq_eks_cluster" {
  type                     = "ingress"
  description              = "AMQPS from EKS cluster additional security group"
  from_port                = 5671
  to_port                  = 5671
  protocol                 = "tcp"
  security_group_id        = aws_security_group.hyperfleet_mq.id
  source_security_group_id = var.eks_cluster_security_group_id
}

# Ingress rule: AMQPS from EKS cluster primary security group (Auto Mode nodes)
# This SG comes from the EKS module and is available after EKS creation.
# It does NOT block broker creation - only defines who can connect.
resource "aws_security_group_rule" "hyperfleet_mq_eks_primary" {
  type                     = "ingress"
  description              = "AMQPS from EKS cluster primary security group (Auto Mode)"
  from_port                = 5671
  to_port                  = 5671
  protocol                 = "tcp"
  security_group_id        = aws_security_group.hyperfleet_mq.id
  source_security_group_id = var.eks_cluster_primary_security_group_id
}

# Ingress rule: RabbitMQ management console from bastion (if enabled)
resource "aws_security_group_rule" "hyperfleet_mq_bastion" {
  count = var.bastion_enabled ? 1 : 0

  type                     = "ingress"
  description              = "HTTPS for RabbitMQ console from bastion"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.hyperfleet_mq.id
  source_security_group_id = var.bastion_security_group_id
}

# Amazon MQ Broker
# Only depends on VPC + its own security group. Ingress rules are independent.
resource "aws_mq_broker" "hyperfleet" {
  broker_name = "${var.regional_id}-hyperfleet"

  engine_type    = "RabbitMQ"
  engine_version = var.mq_engine_version

  host_instance_type = var.mq_instance_type
  deployment_mode    = var.mq_deployment_mode

  storage_type = "ebs"

  subnet_ids          = var.mq_deployment_mode == "CLUSTER_MULTI_AZ" ? slice(var.private_subnets, 0, 2) : [var.private_subnets[0]]
  security_groups     = [aws_security_group.hyperfleet_mq.id]
  publicly_accessible = false

  user {
    username = var.mq_username
    password = random_password.mq_password.result
  }

  encryption_options {
    use_aws_owned_key = true
  }

  auto_minor_version_upgrade = true
  maintenance_window_start_time {
    day_of_week = "MONDAY"
    time_of_day = "04:00"
    time_zone   = "UTC"
  }

  logs {
    general = true
  }

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.regional_id}-hyperfleet-mq"
      Component = "hyperfleet-sentinel"
    }
  )
}
