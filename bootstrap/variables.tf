variable "aws_region" {
  description = "Region for the state bucket and lock table. Terraform state backends aren't region-bound to where resources live, but us-east-1 matches everything else in this project."
  type        = string
  default     = "us-east-1"
}
