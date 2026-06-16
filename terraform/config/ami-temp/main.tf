provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------
# KMS key for EBS encryption of FIPS RHEL EKS AMI builds
# -----------------------------------------------------------------------------

resource "aws_iam_role" "packer" {
  name = "packer-ami-build"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = var.trusted_principal_arns }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { temporary = "true" }
}

resource "aws_kms_key" "ami" {
  description             = "EBS encryption key for FIPS RHEL EKS AMI builds"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootManagement"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowPackerRole"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.packer.arn
        }
        Action = [
          "kms:CreateGrant",
          "kms:DescribeKey",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:ReEncryptFrom",
          "kms:ReEncryptTo",
        ]
        Resource = "*"
      },
      {
        # Build instance writes to its KMS-encrypted EBS root volume during provisioning
        Sid    = "AllowBuildInstanceRole"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.build_instance.arn
        }
        Action = [
          "kms:CreateGrant",
          "kms:DescribeKey",
          "kms:GenerateDataKeyWithoutPlaintext",
        ]
        Resource = "*"
      },
      {
        # EC2 calls DescribeKey to verify the key before creating a grant.
        # Must be a separate statement — kms:GrantIsForAWSResource is only set
        # on CreateGrant calls, not DescribeKey.
        Sid    = "AllowCrossAccountDescribeKey"
        Effect = "Allow"
        Principal = {
          AWS = [for id in var.ami_consumer_account_ids : "arn:aws:iam::${id}:root"]
        }
        Action   = ["kms:DescribeKey"]
        Resource = "*"
      },
      {
        # EC2 needs these to copy snapshot data into a new volume in the target
        # account. Required in addition to CreateGrant for cross-account EBS.
        Sid    = "AllowCrossAccountCryptoOps"
        Effect = "Allow"
        Principal = {
          AWS = [for id in var.ami_consumer_account_ids : "arn:aws:iam::${id}:root"]
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:ReEncryptFrom",
          "kms:ReEncryptTo",
        ]
        Resource = "*"
      },
      {
        # Allows EC2 in the target accounts to create grants at instance launch
        # so nodes can decrypt the encrypted EBS root volume at runtime.
        Sid    = "AllowCrossAccountCreateGrant"
        Effect = "Allow"
        Principal = {
          AWS = [for id in var.ami_consumer_account_ids : "arn:aws:iam::${id}:root"]
        }
        Action   = ["kms:CreateGrant"]
        Resource = "*"
        Condition = {
          Bool = { "kms:GrantIsForAWSResource" = "true" }
        }
      },
    ]
  })

  tags = { temporary = "true" }
}

resource "aws_kms_alias" "ami" {
  name          = "alias/fips-rhel-eks-ami"
  target_key_id = aws_kms_key.ami.key_id
}

# -----------------------------------------------------------------------------
# IAM policy granting Packer the permissions it needs to build AMIs
# -----------------------------------------------------------------------------

resource "aws_iam_policy" "ami_builder" {
  name = "ami-builder"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:AttachVolume",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:CopyImage",
          "ec2:CreateImage",
          "ec2:CreateKeypair",
          "ec2:CreateSecurityGroup",
          "ec2:CreateSnapshot",
          "ec2:CreateTags",
          "ec2:CreateVolume",
          "ec2:DeleteKeyPair",
          "ec2:DeleteSecurityGroup",
          "ec2:DeleteSnapshot",
          "ec2:DeleteVolume",
          "ec2:DeregisterImage",
          "ec2:DescribeImageAttribute",
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceStatus",
          "ec2:DescribeRegions",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSnapshots",
          "ec2:DescribeSubnets",
          "ec2:DescribeTags",
          "ec2:DescribeVolumes",
          "ec2:DetachVolume",
          "ec2:GetPasswordData",
          "ec2:ModifyImageAttribute",
          "ec2:ModifyInstanceAttribute",
          "ec2:ModifySnapshotAttribute",
          "ec2:RegisterImage",
          "ec2:RunInstances",
          "ec2:StopInstances",
          "ec2:TerminateInstances",
          "eks:DescribeAddonVersions",
          "ecr:GetAuthorizationToken",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
        ]
        # EKS public ECR account — region-specific, must match aws_region in make build
        Resource = "arn:aws:ecr:${var.region}:602401143452:repository/*"
      },
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::amazon-eks/*",
          "arn:aws:s3:::amazon-eks",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:CreateGrant",
          "kms:DescribeKey",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:ReEncryptFrom",
          "kms:ReEncryptTo",
        ]
        Resource = aws_kms_key.ami.arn
      },
      {
        # Packer calls GetInstanceProfile to validate it exists, then PassRole when calling RunInstances
        Effect = "Allow"
        Action = ["iam:GetInstanceProfile", "iam:PassRole"]
        Resource = [
          aws_iam_role.build_instance.arn,
          aws_iam_instance_profile.build_instance.arn,
        ]
      },
    ]
  })

  tags = { temporary = "true" }
}

resource "aws_iam_role_policy_attachment" "packer" {
  role       = aws_iam_role.packer.name
  policy_arn = aws_iam_policy.ami_builder.arn
}

# -----------------------------------------------------------------------------
# IAM role and instance profile for the Packer build EC2 instance
#
# Distinct from packer-ami-build (used by the Packer process itself). The build
# instance needs credentials to pull the pause container from ECR and to write
# to the KMS-encrypted EBS root volume during provisioning.
# Pass the profile name as iam_instance_profile in the make k8s command.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "build_instance" {
  name = "packer-ami-build-instance"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { temporary = "true" }
}

resource "aws_iam_role_policy" "build_instance" {
  name = "ami-build-instance"
  role = aws_iam_role.build_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = "arn:aws:ecr:${var.region}:602401143452:repository/*"
      },
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::amazon-eks/*",
          "arn:aws:s3:::amazon-eks",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:CreateGrant",
          "kms:DescribeKey",
          "kms:GenerateDataKeyWithoutPlaintext",
        ]
        Resource = aws_kms_key.ami.arn
      },
    ]
  })
}

resource "aws_iam_instance_profile" "build_instance" {
  name = "packer-ami-build-instance"
  role = aws_iam_role.build_instance.name

  tags = { temporary = "true" }
}

# -----------------------------------------------------------------------------
# VPC for Packer build instances
# -----------------------------------------------------------------------------

resource "aws_vpc" "build" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "ami-build", temporary = "true" }
}

resource "aws_internet_gateway" "build" {
  vpc_id = aws_vpc.build.id

  tags = { Name = "ami-build", temporary = "true" }
}

resource "aws_subnet" "build" {
  vpc_id                  = aws_vpc.build.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.region}a"
  map_public_ip_on_launch = false

  tags = { Name = "ami-build", temporary = "true" }
}

resource "aws_route_table" "build" {
  vpc_id = aws_vpc.build.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.build.id
  }

  tags = { Name = "ami-build", temporary = "true" }
}

resource "aws_route_table_association" "build" {
  subnet_id      = aws_subnet.build.id
  route_table_id = aws_route_table.build.id
}
