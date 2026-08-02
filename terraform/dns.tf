resource "aws_route53_record" "web_a" {
  zone_id = local.zone_id
  name    = local.web_domain
  type    = "A"

  alias {
    name                   = module.web.distribution_domain_name
    zone_id                = module.web.distribution_hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "web_aaaa" {
  zone_id = local.zone_id
  name    = local.web_domain
  type    = "AAAA"

  alias {
    name                   = module.web.distribution_domain_name
    zone_id                = module.web.distribution_hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "api_a" {
  zone_id = local.zone_id
  name    = local.api_domain
  type    = "A"

  alias {
    name                   = module.web.distribution_domain_name
    zone_id                = module.web.distribution_hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "api_aaaa" {
  zone_id = local.zone_id
  name    = local.api_domain
  type    = "AAAA"

  alias {
    name                   = module.web.distribution_domain_name
    zone_id                = module.web.distribution_hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "admin_a" {
  zone_id = local.zone_id
  name    = local.admin_domain
  type    = "A"

  alias {
    name                   = module.admin.distribution_domain_name
    zone_id                = module.admin.distribution_hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "admin_aaaa" {
  zone_id = local.zone_id
  name    = local.admin_domain
  type    = "AAAA"

  alias {
    name                   = module.admin.distribution_domain_name
    zone_id                = module.admin.distribution_hosted_zone_id
    evaluate_target_health = false
  }
}
