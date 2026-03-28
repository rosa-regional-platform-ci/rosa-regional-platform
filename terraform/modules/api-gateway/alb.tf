# =============================================================================
# Internal Application Load Balancer
#
# This ALB is created by Terraform and remains empty until ArgoCD deploys
# a TargetGroupBinding that registers pod IPs into the target group.
#
# Flow: API Gateway -> VPC Link -> ALB -> Target Group -> Pods
# =============================================================================

# -----------------------------------------------------------------------------
# Application Load Balancer
# -----------------------------------------------------------------------------

resource "aws_lb" "platform" {
  name               = "${var.regional_id}-api"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.private_subnet_ids

  tags = {
    Name = "${var.regional_id}-api"
  }
}

# -----------------------------------------------------------------------------
# Target Group
#
# Uses IP target type for TargetGroupBinding compatibility.
# EKS Auto Mode will register pod IPs when the TargetGroupBinding resource
# is created in Kubernetes.
#
# IMPORTANT: The eks:eks-cluster-name tag is REQUIRED for EKS Auto Mode.
# The AmazonEKSLoadBalancingPolicy has a condition that only allows
# RegisterTargets on target groups tagged with the cluster name.
# -----------------------------------------------------------------------------

resource "aws_lb_target_group" "platform" {
  name        = "${var.regional_id}-api"
  port        = var.target_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip" # Required for TargetGroupBinding

  health_check {
    enabled             = true
    path                = var.health_check_path
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = var.health_check_timeout
    interval            = var.health_check_interval
    matcher             = "200"
  }

  tags = {
    Name                   = "${var.regional_id}-api"
    "eks:eks-cluster-name" = var.cluster_name
  }
}

# -----------------------------------------------------------------------------
# Thanos Receive Target Group
#
# Receives Prometheus remote_write metrics from Management Clusters.
# Same pattern as the platform target group: IP target type with
# eks:eks-cluster-name tag for EKS Auto Mode compatibility.
# -----------------------------------------------------------------------------

resource "aws_lb_target_group" "thanos" {
  name        = "${var.regional_id}-thanos"
  port        = var.thanos_target_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/-/ready"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = {
    Name                   = "${var.regional_id}-thanos"
    "eks:eks-cluster-name" = var.cluster_name
  }
}

# -----------------------------------------------------------------------------
# Listener
# -----------------------------------------------------------------------------

resource "aws_lb_listener" "platform" {
  load_balancer_arn = aws_lb.platform.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.platform.arn
  }
}

# -----------------------------------------------------------------------------
# Thanos Receive Listener Rule
#
# Path-based routing: /api/v1/receive -> Thanos target group.
# Takes priority over the default action (platform-api).
# -----------------------------------------------------------------------------

resource "aws_lb_listener_rule" "thanos_receive" {
  listener_arn = aws_lb_listener.platform.arn
  priority     = 10

  condition {
    path_pattern {
      values = ["/api/v1/receive"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.thanos.arn
  }
}
