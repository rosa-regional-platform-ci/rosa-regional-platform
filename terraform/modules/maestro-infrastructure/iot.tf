# =============================================================================
# AWS IoT Core Resources
#
# Creates certificates and policies for Maestro Server to communicate over MQTT
# on port 8883 with certificate-based authentication.
#
# Note: IoT Things are NOT created - they're only needed for Device Shadows
# and IoT Jobs, which Maestro doesn't use. MQTT only requires cert + policy.
# =============================================================================

# Get AWS IoT Core MQTT endpoint
data "aws_iot_endpoint" "mqtt" {
  endpoint_type = "iot:Data-ATS"
}

# Download AWS IoT Root CA certificate
data "http" "aws_iot_root_ca" {
  url = "https://www.amazontrust.com/repository/AmazonRootCA1.pem"
}

# =============================================================================
# Maestro Server - IoT Certificate and Policy
# =============================================================================

resource "aws_iot_certificate" "maestro_server" {
  active = true
}

# IoT Policy for Maestro Server (Publisher/Subscriber)
resource "aws_iot_policy" "maestro_server" {
  name = "${var.regional_id}-maestro-server-policy"

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
        Action = ["iot:Publish"]
        Resource = [
          "arn:aws:iot:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:topic/sources/maestro/consumers/*/sourceevents",
          "arn:aws:iot:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:topic/sources/maestro/consumers/*/agentevents"
        ]
      },
      {
        Effect = "Allow"
        Action = ["iot:Subscribe"]
        Resource = [
          "arn:aws:iot:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:topicfilter/sources/maestro/consumers/*/agentevents"
        ]
      },
      {
        Effect = "Allow"
        Action = ["iot:Receive"]
        Resource = [
          "arn:aws:iot:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:topic/sources/maestro/consumers/*/agentevents"
        ]
      }
    ]
  })

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.regional_id}-maestro-server-policy"
      Component = "maestro-server"
    }
  )
}

resource "aws_iot_policy_attachment" "maestro_server" {
  policy = aws_iot_policy.maestro_server.name
  target = aws_iot_certificate.maestro_server.arn
}

# =============================================================================
# IoT Core Logging
# =============================================================================

resource "aws_iam_role" "iot_logging" {
  name = "${var.regional_id}-iot-logging"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "iot.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.regional_id}-iot-logging"
      Component = "iot-core"
    }
  )
}

resource "aws_iam_role_policy_attachment" "iot_logging" {
  role       = aws_iam_role.iot_logging.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSIoTLogging"
}

resource "aws_iot_logging_options" "this" {
  role_arn          = aws_iam_role.iot_logging.arn
  default_log_level = var.iot_log_level

  depends_on = [aws_iam_role_policy_attachment.iot_logging]
}

