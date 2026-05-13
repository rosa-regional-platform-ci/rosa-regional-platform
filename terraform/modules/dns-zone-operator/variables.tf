# =============================================================================
# DNS Zone Operator Module Variables
# =============================================================================

variable "regional_id" {
  description = "Regional cluster identifier for resource naming"
  type        = string
}

variable "zone_shard_hosted_zone_ids" {
  description = "Route53 hosted zone IDs for zone shards that operators can manage"
  type        = list(string)
}

variable "mc_ou_path" {
  description = "AWS Organizations OU path for MC accounts (e.g. o-abc123/r-abc1/ou-abc1-abc12345/*). Used in trust policy to allow any MC in the OU to assume this role."
  type        = string

  validation {
    condition     = can(regex("^o-[a-z0-9]+/r-[a-z0-9]+/ou-[a-z0-9]+-[a-z0-9]+(/ou-[a-z0-9]+-[a-z0-9]+)*/\\*$", var.mc_ou_path))
    error_message = "mc_ou_path must be a valid AWS Organizations OU path ending with /*: o-xxx/r-xxx/ou-xxx-xxx/*"
  }
}
