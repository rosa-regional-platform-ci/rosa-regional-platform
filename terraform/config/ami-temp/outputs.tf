output "kms_key_arn" {
  description = "KMS key ARN — pass as kms_key_id in make build"
  value       = aws_kms_key.ami.arn
}

output "role_arn" {
  description = "IAM role ARN — pass to aws sts assume-role before building"
  value       = aws_iam_role.packer.arn
}

output "vpc_id" {
  description = "VPC ID for Packer build instances — pass as vpc_id in make build"
  value       = aws_vpc.build.id
}

output "subnet_id" {
  description = "Subnet ID for Packer build instances — pass as subnet_id in make build"
  value       = aws_subnet.build.id
}

output "instance_profile_name" {
  description = "IAM instance profile for Packer build instances — pass as iam_instance_profile in make build"
  value       = aws_iam_instance_profile.build_instance.name
}

output "assume_role_command" {
  description = "Shell command to export temporary credentials before running make build"
  value       = <<-EOT
    eval $(aws sts assume-role \
      --role-arn ${aws_iam_role.packer.arn} \
      --role-session-name packer-ami-build \
      --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
      --output text | awk '{print "export AWS_ACCESS_KEY_ID="$1"\nexport AWS_SECRET_ACCESS_KEY="$2"\nexport AWS_SESSION_TOKEN="$3}')
  EOT
}
