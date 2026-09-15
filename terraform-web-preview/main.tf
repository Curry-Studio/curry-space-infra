terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Partial config — bucket/region/dynamodb_table are fixed, key is passed
  # at init time. See ../README.md for the exact command.
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "curry-space"
      Environment = var.preview_name
      ManagedBy   = "terraform"
      Purpose     = "frontend-preview"
    }
  }
}

# Reads the global config's state to get the shared ACM cert and hosted
# zone ID, same pattern as ../terraform/main.tf.
data "terraform_remote_state" "global" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "global/terraform.tfstate"
    region = var.aws_region
  }
}
