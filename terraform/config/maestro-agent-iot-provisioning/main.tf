provider "aws" {
  default_tags {
    tags = {
      app-code      = var.app_code
      service-phase = var.service_phase
      cost-center   = var.cost_center
    }
  }
}

data "aws_caller_identity" "current" {}

# Call the maestro-agent-iot-provisioning module
module "maestro_agent_iot" {
  source = "../../modules/maestro-agent-iot-provisioning"

  management_cluster_id = var.management_cluster_id
  mqtt_topic_prefix     = var.mqtt_topic_prefix

  tags = merge(
    var.tags,
    {
      ProvisioningMethod = "pipeline"
      ManagedBy          = "terraform"
    }
  )
}

module "oidc_bucket" {
  source = "../../modules/oidc-bucket"

  management_cluster_id = var.management_cluster_id
  mc_account_id         = var.mc_account_id
  tags                  = var.tags
}
