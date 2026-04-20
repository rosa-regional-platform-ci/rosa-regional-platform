variable "cluster_id" {
  description = "Unique cluster identifier used as a name prefix for all resources"
  type        = string
}

variable "enable_eks_runtime_monitoring" {
  description = "Enable GuardDuty EKS Runtime Monitoring (EKS_RUNTIME_MONITORING feature). This feature is not available in all AWS regions. Disable for regions that do not support it (e.g., some AP/SA regions)."
  type        = bool
  default     = true
}
