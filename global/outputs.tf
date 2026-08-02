output "wildcard_cert_arn" {
  description = "ACM cert ARN (curry.space + *.curry.space, us-east-1). Every environment's CloudFront distributions use this."
  value       = aws_acm_certificate_validation.wildcard.certificate_arn
}

output "zone_id" {
  description = "Route 53 hosted zone ID for curry.space."
  value       = data.aws_route53_zone.primary.zone_id
}

output "github_actions_role_arn" {
  description = "Set this as the AWS_ROLE_ARN repository variable in curry-space-infra for the Terraform workflow to assume."
  value       = aws_iam_role.github_actions_deploy.arn
}
