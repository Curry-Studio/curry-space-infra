# Two CLOUDFRONT-scope Web ACLs (architecture doc §5.7/§6.1): one for the
# public distribution, one for admin. Both currently default to ALLOW per
# decisions.md D-005 — see variables.tf for admin_waf_default_action.
#
# Scoped deliberately to what the FE-only phase needs: the three baseline
# managed rule groups, plus a general rate limit for staging/production.
# Not yet included — added when the ALB/API backend phase lands, since
# they target paths (/api/auth/*, /api/upload/*, /api/admin/*) that don't
# exist yet: SQLi and Linux managed rule sets, per-path rate limits, geo
# blocking, Bot Control, and the ALB origin-header check.

resource "aws_wafv2_ip_set" "admin_allow" {
  provider           = aws
  name               = "${local.name_prefix}-admin-allow"
  scope              = "CLOUDFRONT"
  ip_address_version = "IPV4"
  addresses          = var.admin_allowed_ip_set
}

locals {
  managed_rule_groups = [
    { name = "AWSManagedRulesAmazonIpReputationList", priority = 10 },
    { name = "AWSManagedRulesCommonRuleSet", priority = 20 },
    { name = "AWSManagedRulesKnownBadInputsRuleSet", priority = 30 },
  ]
}

resource "aws_wafv2_web_acl" "public" {
  name  = "${local.name_prefix}-cf-waf"
  scope = "CLOUDFRONT"

  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = local.managed_rule_groups
    content {
      name     = rule.value.name
      priority = rule.value.priority

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          name        = rule.value.name
          vendor_name = "AWS"
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.value.name
        sampled_requests_enabled   = true
      }
    }
  }

  dynamic "rule" {
    for_each = var.enable_rate_limiting ? [1] : []
    content {
      name     = "general-rate-limit"
      priority = 60

      action {
        block {}
      }

      statement {
        rate_based_statement {
          limit              = 2000
          aggregate_key_type = "IP"
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "general-rate-limit"
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name_prefix}-cf-waf"
    sampled_requests_enabled   = true
  }
}

resource "aws_wafv2_web_acl" "admin" {
  name  = "${local.name_prefix}-admin-waf"
  scope = "CLOUDFRONT"

  default_action {
    dynamic "allow" {
      for_each = var.admin_waf_default_action == "ALLOW" ? [1] : []
      content {}
    }
    dynamic "block" {
      for_each = var.admin_waf_default_action == "BLOCK" ? [1] : []
      content {}
    }
  }

  # Same baseline protection as the public ACL — D-005 turns off the IP
  # gate, not the managed rules or rate limiting.
  dynamic "rule" {
    for_each = local.managed_rule_groups
    content {
      name     = rule.value.name
      priority = rule.value.priority

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          name        = rule.value.name
          vendor_name = "AWS"
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.value.name
        sampled_requests_enabled   = true
      }
    }
  }

  dynamic "rule" {
    for_each = var.enable_rate_limiting ? [1] : []
    content {
      name     = "general-rate-limit"
      priority = 60

      action {
        block {}
      }

      statement {
        rate_based_statement {
          limit              = 2000
          aggregate_key_type = "IP"
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "general-rate-limit"
        sampled_requests_enabled   = true
      }
    }
  }

  # Only meaningful once admin_waf_default_action is flipped to BLOCK —
  # see decisions.md D-005.
  dynamic "rule" {
    for_each = var.admin_waf_default_action == "BLOCK" ? [1] : []
    content {
      name     = "admin-ip-allow"
      priority = 35

      action {
        allow {}
      }

      statement {
        ip_set_reference_statement {
          arn = aws_wafv2_ip_set.admin_allow.arn
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "admin-ip-allow"
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name_prefix}-admin-waf"
    sampled_requests_enabled   = true
  }
}
