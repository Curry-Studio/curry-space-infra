# The hosted zone already exists in Route 53 — Hostinger's nameservers for
# curry.space were repointed at it, which only works if the zone (and its
# NS records) were created first. We look it up rather than create it:
# creating a new aws_route53_zone here would mint a *different* zone with
# different NS values that Hostinger doesn't point at, breaking DNS.
#
# To bring the existing zone under Terraform management later (for
# deletion protection etc.), import it instead of letting a resource block
# create a new one:
#   terraform import aws_route53_zone.primary <existing-zone-id>
data "aws_route53_zone" "primary" {
  name = "curry.space"
}
