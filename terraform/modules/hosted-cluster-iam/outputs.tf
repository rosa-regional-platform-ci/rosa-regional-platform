# =============================================================================
# Hosted Cluster IAM Module - Outputs
# =============================================================================

# OIDC Provider
output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider for the hosted cluster"
  value       = aws_iam_openid_connect_provider.hosted_cluster.arn
}

output "oidc_provider_url" {
  description = "URL of the IAM OIDC provider"
  value       = aws_iam_openid_connect_provider.hosted_cluster.url
}

# Individual role ARNs
output "ingress_role_arn" {
  description = "IAM role ARN for the Ingress Operator"
  value       = aws_iam_role.hosted_control_plane["ingress"].arn
}

output "cloud_controller_manager_role_arn" {
  description = "IAM role ARN for the Cloud Controller Manager"
  value       = aws_iam_role.hosted_control_plane["cloud-controller-manager"].arn
}

output "ebs_csi_role_arn" {
  description = "IAM role ARN for the EBS CSI Driver"
  value       = aws_iam_role.hosted_control_plane["ebs-csi"].arn
}

output "image_registry_role_arn" {
  description = "IAM role ARN for the Image Registry"
  value       = aws_iam_role.hosted_control_plane["image-registry"].arn
}

output "network_config_role_arn" {
  description = "IAM role ARN for the Network Config Controller"
  value       = aws_iam_role.hosted_control_plane["network-config"].arn
}

output "control_plane_operator_role_arn" {
  description = "IAM role ARN for the Control Plane Operator"
  value       = aws_iam_role.hosted_control_plane["control-plane-operator"].arn
}

output "node_pool_management_role_arn" {
  description = "IAM role ARN for Node Pool Management"
  value       = aws_iam_role.hosted_control_plane["node-pool-management"].arn
}

# Map of all role ARNs for programmatic consumption
output "role_arns" {
  description = "Map of role purpose to IAM role ARN for all hosted control plane roles"
  value       = { for k, v in aws_iam_role.hosted_control_plane : k => v.arn }
}

# Worker node outputs
output "worker_role_arn" {
  description = "IAM role ARN for worker node EC2 instances"
  value       = aws_iam_role.worker_node.arn
}

output "worker_instance_profile_name" {
  description = "IAM instance profile name for worker node EC2 instances"
  value       = aws_iam_instance_profile.worker_node.name
}
