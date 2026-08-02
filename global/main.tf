terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Partial config on purpose — bucket/key/region/dynamodb_table are supplied
  # at `terraform init` time via -backend-config, so the account ID doesn't
  # need to be committed. See ../README.md for the exact init command.
  backend "s3" {
    key = "global/terraform.tfstate"
  }
}

provider "aws" {
  region = "us-east-1" # CloudFront certs must live here regardless of where anything else runs.

  default_tags {
    tags = {
      Project   = "curry-space"
      ManagedBy = "terraform-global"
    }
  }
}
