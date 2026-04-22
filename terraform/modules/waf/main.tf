# =============================================================================
# WAF Module — FedRAMP SC-05 Denial of Service Protection
#
# Creates AWS WAFv2 Web ACLs with AWS managed rule groups for regional
# API Gateway stages (REGIONAL scope). Managed rule groups protect against
# common layer-7 attacks (SQLi, XSS, known bad inputs) and provide rate
# limiting to mitigate volumetric DoS.
# =============================================================================

data "aws_region" "current" {}

# =============================================================================
# REGIONAL WAF Web ACL — for API Gateway
# =============================================================================

resource "aws_wafv2_web_acl" "api_gateway" {
  name        = "${var.cluster_id}-api-gateway-waf"
  description = "FedRAMP SC-05: WAFv2 protection for API Gateway stage"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # Rate limiting — 2000 requests per 5 minutes per IP
  rule {
    name     = "rate-limit-per-ip"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.rate_limit_per_5m_per_ip
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.cluster_id}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  # AWS Core Rule Set — general protection (SQLi, XSS, path traversal, etc.)
  rule {
    name     = "aws-core-rule-set"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.cluster_id}-core-rule-set"
      sampled_requests_enabled   = true
    }
  }

  # Known bad inputs — SSRF, Log4J, etc.
  rule {
    name     = "aws-known-bad-inputs"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.cluster_id}-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  # Amazon IP reputation list — block known malicious IPs
  rule {
    name     = "aws-ip-reputation"
    priority = 4

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.cluster_id}-ip-reputation"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.cluster_id}-api-gateway-waf"
    sampled_requests_enabled   = true
  }

  tags = {
    Name    = "${var.cluster_id}-api-gateway-waf"
    FedRAMP = "SC-05"
  }
}

# Associate WAF with the API Gateway stage
resource "aws_wafv2_web_acl_association" "api_gateway" {
  resource_arn = var.api_gateway_stage_arn
  web_acl_arn  = aws_wafv2_web_acl.api_gateway.arn
}

# CloudWatch logging for WAF
resource "aws_cloudwatch_log_group" "waf_api_gateway" {
  # WAF log groups MUST be prefixed with "aws-waf-logs-"
  name              = "aws-waf-logs-${var.cluster_id}-api-gateway"
  retention_in_days = var.log_retention_in_days

  tags = {
    FedRAMP = "SC-05"
  }
}

resource "aws_wafv2_web_acl_logging_configuration" "api_gateway" {
  log_destination_configs = [aws_cloudwatch_log_group.waf_api_gateway.arn]
  resource_arn            = aws_wafv2_web_acl.api_gateway.arn

  redacted_fields {
    single_header {
      name = "authorization"
    }
  }

  redacted_fields {
    single_header {
      name = "cookie"
    }
  }

  redacted_fields {
    single_header {
      name = "x-api-key"
    }
  }
}

# =============================================================================
# CloudWatch Alarms — WAF Blocked Requests (FedRAMP SC-05)
# =============================================================================

resource "aws_cloudwatch_metric_alarm" "waf_rate_limit_blocked" {
  count = var.security_alerts_topic_arn != "" ? 1 : 0

  alarm_name          = "${var.cluster_id}-waf-rate-limit-blocked"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "BlockedRequests"
  namespace           = "AWS/WAFV2"
  period              = 300
  statistic           = "Sum"
  threshold           = var.blocked_requests_alarm_threshold
  alarm_description   = "FedRAMP SC-05: WAF rate-limit rule is blocking a high volume of requests"
  alarm_actions       = [var.security_alerts_topic_arn]
  ok_actions          = [var.security_alerts_topic_arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    WebACL = aws_wafv2_web_acl.api_gateway.name
    Region = data.aws_region.current.id
    Rule   = "rate-limit-per-ip"
  }
}

resource "aws_cloudwatch_metric_alarm" "waf_acl_blocked" {
  count = var.security_alerts_topic_arn != "" ? 1 : 0

  alarm_name          = "${var.cluster_id}-waf-acl-blocked"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "BlockedRequests"
  namespace           = "AWS/WAFV2"
  period              = 300
  statistic           = "Sum"
  threshold           = var.blocked_requests_alarm_threshold
  alarm_description   = "FedRAMP SC-05: WAF ACL is blocking a high volume of requests across all rules"
  alarm_actions       = [var.security_alerts_topic_arn]
  ok_actions          = [var.security_alerts_topic_arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    WebACL = aws_wafv2_web_acl.api_gateway.name
    Region = data.aws_region.current.id
    Rule   = "ALL"
  }
}
