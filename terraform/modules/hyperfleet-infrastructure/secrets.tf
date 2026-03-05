# =============================================================================
# AWS Secrets Manager Resources
#
# Stores database and message queue credentials for HyperFleet components
# These secrets are synced to Kubernetes via AWS Secrets and Configuration Provider (ASCP)
# =============================================================================

# =============================================================================
# HyperFleet Database Credentials
# =============================================================================

resource "aws_secretsmanager_secret" "hyperfleet_db_credentials" {
  name                    = "${var.regional_id}-hyperfleet-db-credentials"
  description             = "PostgreSQL database credentials for HyperFleet API"
  recovery_window_in_days = 0 # Force immediate deletion to allow quick recreation

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.regional_id}-hyperfleet-db-credentials"
      Component = "hyperfleet-api"
    }
  )
}

resource "aws_secretsmanager_secret_version" "hyperfleet_db_credentials" {
  secret_id = aws_secretsmanager_secret.hyperfleet_db_credentials.id

  secret_string = jsonencode({
    username = aws_db_instance.hyperfleet.username
    password = random_password.db_password.result
    host     = aws_db_instance.hyperfleet.address
    port     = tostring(aws_db_instance.hyperfleet.port)
    database = aws_db_instance.hyperfleet.db_name
  })
}

# =============================================================================
# HyperFleet Message Queue Credentials
# =============================================================================

resource "aws_secretsmanager_secret" "hyperfleet_mq_credentials" {
  name                    = "${var.regional_id}-hyperfleet-mq-credentials"
  description             = "Amazon MQ credentials for HyperFleet Sentinel and Adapter"
  recovery_window_in_days = 0 # Force immediate deletion to allow quick recreation

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.regional_id}-hyperfleet-mq-credentials"
      Component = "hyperfleet-sentinel"
    }
  )
}

resource "aws_secretsmanager_secret_version" "hyperfleet_mq_credentials" {
  secret_id = aws_secretsmanager_secret.hyperfleet_mq_credentials.id

  secret_string = jsonencode({
    username = var.mq_username
    password = random_password.mq_password.result
    # Extract hostname from endpoint (endpoint format: amqps://hostname:5671)
    host = replace(replace(aws_mq_broker.hyperfleet.instances[0].endpoints[0], "amqps://", ""), ":5671", "")
    port = "5671"
    # Build URL with URL-encoded password to handle special characters
    url = "amqps://${urlencode(var.mq_username)}:${urlencode(random_password.mq_password.result)}@${replace(replace(aws_mq_broker.hyperfleet.instances[0].endpoints[0], "amqps://", ""), ":5671", "")}:5671"
  })
}
