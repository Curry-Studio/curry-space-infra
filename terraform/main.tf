terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Partial config — bucket/region/dynamodb_table are fixed across
  # environments, but `key` differs per environment so each one gets its
  # own state file in the same bucket. Supplied at init time; see
  # ../README.md for the exact command per environment.
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "curry-space"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# Reads the global config's state to get the shared ACM cert and hosted
# zone ID, so they don't need to be copy-pasted into every environment's
# tfvars. state_bucket is a variable (not the literal backend bucket)
# because backend blocks can't reference variables — see README.
data "terraform_remote_state" "global" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "global/terraform.tfstate"
    region = var.aws_region
  }
}
