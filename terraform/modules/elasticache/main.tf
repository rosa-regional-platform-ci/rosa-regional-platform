# =============================================================================
# ElastiCache Redis Module
#
# Creates an ElastiCache Redis replication group for Thanos Query Frontend
# response caching. Reduces S3 fetch latency for repeated queries.
#
# Security posture:
#   - Encryption at rest via dedicated KMS key (FedRAMP requirement)
#   - Encryption in transit (TLS, FedRAMP requirement)
#   - Network isolation: only EKS node security group can reach Redis port
# =============================================================================

data "aws_region" "current" {}

locals {
  name = "${var.cluster_id}-thanos-cache"
}

# =============================================================================
# KMS Key for Encryption at Rest (FedRAMP Requirement)
# =============================================================================

resource "aws_kms_key" "elasticache" {
  description             = "KMS key for Thanos query cache ElastiCache encryption at rest"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = {
    Name = local.name
  }
}

resource "aws_kms_alias" "elasticache" {
  name          = "alias/${local.name}"
  target_key_id = aws_kms_key.elasticache.key_id
}

# =============================================================================
# Security Group
# =============================================================================

resource "aws_security_group" "elasticache" {
  name        = local.name
  description = "Security group for Thanos query cache ElastiCache Redis"
  vpc_id      = var.vpc_id

  tags = {
    Name = local.name
  }
}

resource "aws_vpc_security_group_ingress_rule" "from_eks_nodes" {
  security_group_id            = aws_security_group.elasticache.id
  referenced_security_group_id = var.node_security_group_id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  description                  = "Allow Redis access from EKS nodes"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.elasticache.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow all outbound traffic"
}

# =============================================================================
# Subnet Group
# =============================================================================

resource "aws_elasticache_subnet_group" "redis" {
  name       = local.name
  subnet_ids = var.private_subnet_ids

  tags = {
    Name = local.name
  }
}

# =============================================================================
# ElastiCache Redis Replication Group
#
# Non-cluster mode: 1 primary + optional replica.
# Thanos's go-redis client does not support Redis Cluster protocol.
# =============================================================================

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = local.name
  description          = "Thanos query frontend response cache"

  engine         = "redis"
  engine_version = var.engine_version
  node_type      = var.node_type
  port           = 6379

  # 1 primary + 1 replica for HA, or just primary for dev/staging
  num_cache_clusters         = var.multi_az ? 2 : 1
  automatic_failover_enabled = var.multi_az
  multi_az_enabled           = var.multi_az

  subnet_group_name  = aws_elasticache_subnet_group.redis.name
  security_group_ids = [aws_security_group.elasticache.id]

  # Encryption at rest (FedRAMP requirement)
  at_rest_encryption_enabled = true
  kms_key_id                 = aws_kms_key.elasticache.arn

  # Encryption in transit (FedRAMP requirement)
  # Redis 7.x supports TLS without requiring an auth token.
  # Network-level isolation (VPC + security groups) provides primary access control.
  transit_encryption_enabled = true

  apply_immediately          = true
  auto_minor_version_upgrade = true

  tags = {
    Name = local.name
  }
}
