locals {
  name_prefix = "cs-${var.preview_name}-use1"

  # Flat hostname pattern, same as ../terraform/locals.tf: a single
  # *.curry.space wildcard covers this too.
  web_domain = "${var.preview_name}.curry.space"

  cert_arn = data.terraform_remote_state.global.outputs.wildcard_cert_arn
  zone_id  = data.terraform_remote_state.global.outputs.zone_id
}
