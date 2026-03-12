# =============================================================================
# VPC and Networking Configuration
#
# Creates a VPC for hosted cluster worker nodes with:
# - Multi-AZ private/public subnets
# - NAT Gateway(s) for private subnet egress
# - Configurable single or per-AZ NAT for cost vs. HA trade-off
# =============================================================================

# -----------------------------------------------------------------------------
# VPC and Internet Gateway
# -----------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-vpc"
  })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-igw"
  })
}

# -----------------------------------------------------------------------------
# Subnets
#
# Public subnets: For load balancers and NAT gateway placement
# Private subnets: For hosted cluster worker nodes (no direct internet access)
# -----------------------------------------------------------------------------

resource "aws_subnet" "public" {
  count             = length(var.public_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(local.common_tags, {
    Name                     = "${local.name_prefix}-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb" = "1"
  })
}

resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(local.common_tags, {
    Name                                = "${local.name_prefix}-private-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb"   = "1"
  })
}

# -----------------------------------------------------------------------------
# NAT Gateways for Internet Egress
#
# When single_nat_gateway = true:  One NAT in the first public subnet (dev/test)
# When single_nat_gateway = false: Per-AZ NATs for high availability (production)
# -----------------------------------------------------------------------------

resource "aws_eip" "nat" {
  count  = var.single_nat_gateway ? 1 : length(var.public_subnet_cidrs)
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-nat-eip-${local.azs[count.index]}"
  })
}

resource "aws_nat_gateway" "main" {
  count         = var.single_nat_gateway ? 1 : length(var.public_subnet_cidrs)
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  depends_on    = [aws_internet_gateway.main]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-nat-gw-${local.azs[count.index]}"
  })
}

# -----------------------------------------------------------------------------
# Routing Tables
#
# Public routes: Direct traffic through Internet Gateway
# Private routes: Route traffic through NAT Gateway(s)
#   - single_nat_gateway = true:  One route table for all private subnets
#   - single_nat_gateway = false: Per-AZ route tables to local NAT Gateway
# -----------------------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-public-rt"
  })
}

resource "aws_route_table" "private" {
  count  = var.single_nat_gateway ? 1 : length(var.private_subnet_cidrs)
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }

  tags = merge(local.common_tags, {
    Name = var.single_nat_gateway ? "${local.name_prefix}-private-rt" : "${local.name_prefix}-private-rt-${local.azs[count.index]}"
  })
}

# -----------------------------------------------------------------------------
# Route Table Associations
# -----------------------------------------------------------------------------

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = var.single_nat_gateway ? aws_route_table.private[0].id : aws_route_table.private[count.index].id
}

# -----------------------------------------------------------------------------
# Worker Node Security Group
#
# Allows all traffic between worker nodes in the VPC and egress to the
# internet. Ingress from external sources is not permitted.
# -----------------------------------------------------------------------------

resource "aws_security_group" "worker" {
  name        = "${local.name_prefix}-worker-sg"
  description = "Security group for hosted cluster worker nodes"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-worker-sg"
  })
}

resource "aws_vpc_security_group_ingress_rule" "worker_self" {
  security_group_id            = aws_security_group.worker.id
  referenced_security_group_id = aws_security_group.worker.id
  ip_protocol                  = "-1"
  description                  = "Allow all traffic between worker nodes"
}

resource "aws_vpc_security_group_ingress_rule" "worker_vpc" {
  security_group_id = aws_security_group.worker.id
  cidr_ipv4         = aws_vpc.main.cidr_block
  ip_protocol       = "-1"
  description       = "Allow all traffic from within the VPC"
}

resource "aws_vpc_security_group_egress_rule" "worker_all" {
  security_group_id = aws_security_group.worker.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow all outbound traffic"
}

# -----------------------------------------------------------------------------
# Private Hosted Zone for PrivateLink DNS
#
# The HyperShift awsendpointservice controller creates DNS records (CNAME) in
# this zone pointing API server and router hostnames to VPC endpoint IPs.
# In standard ROSA this is created by `hypershift create infra aws`.
# -----------------------------------------------------------------------------

resource "aws_route53_zone" "hypershift_local" {
  name = "${var.cluster_name}.hypershift.local"

  vpc {
    vpc_id = aws_vpc.main.id
  }

  tags = merge(local.common_tags, {
    Name                                           = "${var.cluster_name}.hypershift.local"
    "kubernetes.io/cluster/${var.cluster_name}"     = "owned"
  })
}
