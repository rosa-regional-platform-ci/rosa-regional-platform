# =============================================================================
# Amazon MQ for RabbitMQ
#
# Message broker for HyperFleet Sentinel (publisher) and Adapter (consumer)
# communication
# =============================================================================

# Generate secure random password for broker
resource "random_password" "mq_password" {
  length  = 32
  special = true
  # Amazon MQ prohibits: comma (,), colon (:), equals (=), square brackets ([])
  override_special = "!#$%&*()-_+{}?"
}

# Security Group for Amazon MQ - only allow access from EKS cluster
resource "aws_security_group" "hyperfleet_mq" {
  name        = "${var.regional_id}-hyperfleet-mq"
  description = "Security group for HyperFleet Amazon MQ broker"
  vpc_id      = var.vpc_id

  # Prevent Terraform from trying to detach ENIs
  revoke_rules_on_delete = false

  # Allow AMQPS (5671) from EKS cluster additional security group
  ingress {
    description     = "AMQPS from EKS cluster additional security group"
    from_port       = 5671
    to_port         = 5671
    protocol        = "tcp"
    security_groups = [var.eks_cluster_security_group_id]
  }

  # Allow AMQPS from EKS cluster primary security group (Auto Mode nodes)
  ingress {
    description     = "AMQPS from EKS cluster primary security group (Auto Mode)"
    from_port       = 5671
    to_port         = 5671
    protocol        = "tcp"
    security_groups = [var.eks_cluster_primary_security_group_id]
  }

  # Allow RabbitMQ management console (443) from bastion (if enabled)
  dynamic "ingress" {
    for_each = var.bastion_security_group_id != null ? [1] : []
    content {
      description     = "HTTPS for RabbitMQ console from bastion"
      from_port       = 443
      to_port         = 443
      protocol        = "tcp"
      security_groups = [var.bastion_security_group_id]
    }
  }

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

# Amazon MQ Broker
resource "aws_mq_broker" "hyperfleet" {
  broker_name = "${var.regional_id}-hyperfleet"

  # Engine configuration
  engine_type    = "RabbitMQ"
  engine_version = var.mq_engine_version

  # Instance configuration
  host_instance_type = var.mq_instance_type
  deployment_mode    = var.mq_deployment_mode

  # Storage configuration
  storage_type = "ebs"

  # Network configuration
  # For SINGLE_INSTANCE: uses first subnet
  # For CLUSTER_MULTI_AZ: uses first two subnets (requires 2 AZs)
  subnet_ids          = var.mq_deployment_mode == "CLUSTER_MULTI_AZ" ? slice(var.private_subnets, 0, 2) : [var.private_subnets[0]]
  security_groups     = [aws_security_group.hyperfleet_mq.id]
  publicly_accessible = false

  # Authentication
  user {
    username = var.mq_username
    password = random_password.mq_password.result
  }

  # Encryption at rest (AWS-managed keys)
  encryption_options {
    use_aws_owned_key = true
  }

  # Maintenance and updates
  auto_minor_version_upgrade = true
  maintenance_window_start_time {
    day_of_week = "MONDAY"
    time_of_day = "04:00"
    time_zone   = "UTC"
  }

  # Logging
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

  depends_on = [aws_security_group.hyperfleet_mq]
}
