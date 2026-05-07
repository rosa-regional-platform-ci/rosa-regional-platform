# =============================================================================
# RHOBS Internal Application Load Balancer
#
# Dedicated ALB for RHOBS (observability) traffic, completely isolated from the
# Platform API ALB. This ensures that only requests routed through the RHOBS
# API Gateway (with its own restrictive resource policy) can reach Thanos
# services. No path-based routing shared with customer-facing traffic.
#
# Flow: RHOBS API Gateway -> VPC Link -> RHOBS ALB -> Thanos Receive (:19291)
# =============================================================================

# -----------------------------------------------------------------------------
# Application Load Balancer
# -----------------------------------------------------------------------------

resource "aws_lb" "rhobs" {
  name               = "${var.regional_id}-rhobs"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.private_subnet_ids

  tags = {
    Name = "${var.regional_id}-rhobs"
  }
}

# -----------------------------------------------------------------------------
# Thanos Receive Target Group
#
# Receives Prometheus remote_write from Management Clusters via RHOBS API GW.
# Uses IP target type for TargetGroupBinding compatibility with EKS Auto Mode.
# -----------------------------------------------------------------------------

resource "aws_lb_target_group" "thanos_receive" {
  name        = "${var.regional_id}-thanos-recv"
  port        = var.thanos_receive_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/-/ready"
    port                = var.thanos_receive_health_port
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = {
    Name                   = "${var.regional_id}-thanos-recv"
    "eks:eks-cluster-name" = var.cluster_name
  }
}

# -----------------------------------------------------------------------------
# Listener
#
# Single listener forwarding all traffic to Thanos Receive. No path-based
# routing needed since this ALB is dedicated to RHOBS traffic only.
# -----------------------------------------------------------------------------

resource "aws_lb_listener" "rhobs" {
  load_balancer_arn = aws_lb.rhobs.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.thanos_receive.arn
  }
}
