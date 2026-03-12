# =============================================================================
# Hosted Cluster IAM Configuration - Outputs
# =============================================================================

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider"
  value       = module.hosted_cluster_iam.oidc_provider_arn
}

output "ingress_role_arn" {
  description = "IAM role ARN for the Ingress Operator"
  value       = module.hosted_cluster_iam.ingress_role_arn
}

output "cloud_controller_manager_role_arn" {
  description = "IAM role ARN for the Cloud Controller Manager"
  value       = module.hosted_cluster_iam.cloud_controller_manager_role_arn
}

output "ebs_csi_role_arn" {
  description = "IAM role ARN for the EBS CSI Driver"
  value       = module.hosted_cluster_iam.ebs_csi_role_arn
}

output "image_registry_role_arn" {
  description = "IAM role ARN for the Image Registry"
  value       = module.hosted_cluster_iam.image_registry_role_arn
}

output "network_config_role_arn" {
  description = "IAM role ARN for the Network Config Controller"
  value       = module.hosted_cluster_iam.network_config_role_arn
}

output "control_plane_operator_role_arn" {
  description = "IAM role ARN for the Control Plane Operator"
  value       = module.hosted_cluster_iam.control_plane_operator_role_arn
}

output "node_pool_management_role_arn" {
  description = "IAM role ARN for Node Pool Management"
  value       = module.hosted_cluster_iam.node_pool_management_role_arn
}

output "role_arns" {
  description = "Map of all role ARNs"
  value       = module.hosted_cluster_iam.role_arns
}

output "worker_role_arn" {
  description = "IAM role ARN for worker node EC2 instances"
  value       = module.hosted_cluster_iam.worker_role_arn
}

output "worker_instance_profile_name" {
  description = "IAM instance profile name for worker node EC2 instances"
  value       = module.hosted_cluster_iam.worker_instance_profile_name
}
