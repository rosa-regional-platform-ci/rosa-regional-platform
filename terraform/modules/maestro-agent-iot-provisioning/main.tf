# =============================================================================
# Maestro Agent IoT Provisioning Module
#
# Provisions AWS IoT Core resources for a single Maestro Agent:
# - X.509 Certificate (for MQTT authentication)
# - IoT Policy (MQTT topic permissions)
# - Policy-Certificate attachment
#
# This module is designed to be invoked per-management-cluster after that
# cluster is deployed, enabling just-in-time IoT provisioning.
# 
# =============================================================================

# Get current AWS account and region
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# "iot:Data-FIPS" is not a valid endpoint_type for the aws_iot_endpoint data
# source, so we construct the FIPS endpoint manually and fall back to the
# data source (which returns the account-specific ATS endpoint) elsewhere.
data "aws_iot_endpoint" "mqtt_ats" {
  endpoint_type = "iot:Data-ATS"
}

# Download AWS IoT Root CA certificate
data "http" "aws_iot_root_ca" {
  url = "https://www.amazontrust.com/repository/AmazonRootCA1.pem"
}

locals {
  # fips_regions must match the canonical list in terraform/config/*/main.tf.
  fips_regions      = ["us-east-1", "us-east-2", "us-west-1", "us-west-2", "us-gov-east-1", "us-gov-west-1"]
  iot_mqtt_endpoint = contains(local.fips_regions, data.aws_region.current.name) ? "data.iot-fips.${data.aws_region.current.name}.amazonaws.com" : data.aws_iot_endpoint.mqtt_ats.endpoint_address

  common_tags = merge(
    var.tags,
    {
      Component         = "maestro-agent"
      ManagementCluster = var.management_cluster_id
      ManagedBy         = "terraform"
      Module            = "maestro-agent-iot-provisioning"
    }
  )
}

# =============================================================================
# IoT Certificate for Maestro Agent
# =============================================================================

resource "aws_iot_certificate" "maestro_agent" {
  active = true
}

# =============================================================================
# IoT Policy for Maestro Agent (Subscriber/Publisher)
# =============================================================================

resource "aws_iot_policy" "maestro_agent" {
  name = "${var.management_cluster_id}-maestro-agent-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["iot:Connect"]
        Resource = [
          "arn:aws:iot:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:client/*"
        ]
      },
      {
        Effect = "Allow"
        Action = ["iot:Subscribe"]
        Resource = [
          "arn:aws:iot:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:topicfilter/${var.mqtt_topic_prefix}/${var.management_cluster_id}/sourceevents"
        ]
      },
      {
        Effect = "Allow"
        Action = ["iot:Receive"]
        Resource = [
          "arn:aws:iot:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:topic/${var.mqtt_topic_prefix}/${var.management_cluster_id}/sourceevents"
        ]
      },
      {
        Effect = "Allow"
        Action = ["iot:Publish"]
        Resource = [
          "arn:aws:iot:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:topic/${var.mqtt_topic_prefix}/${var.management_cluster_id}/agentevents"
        ]
      }
    ]
  })

  tags = merge(
    local.common_tags,
    {
      Name = "${var.management_cluster_id}-maestro-agent-policy"
    }
  )
}

# =============================================================================
# Attach Policy to Certificate
# =============================================================================

# AWS IoT policy creation is eventually consistent; a brief pause avoids
# "empty result" errors on the immediate read-back after attachment.
resource "time_sleep" "wait_for_iot_policy" {
  depends_on      = [aws_iot_policy.maestro_agent]
  create_duration = "10s"
}

resource "aws_iot_policy_attachment" "maestro_agent" {
  policy = aws_iot_policy.maestro_agent.name
  target = aws_iot_certificate.maestro_agent.arn

  depends_on = [time_sleep.wait_for_iot_policy]
}
