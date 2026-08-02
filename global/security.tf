# --- CloudTrail: all regions, log file validation, delivered to S3 + CloudWatch Logs.

resource "aws_s3_bucket" "cloudtrail" {
  bucket = "cs-cloudtrail-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket                  = aws_s3_bucket.cloudtrail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "cloudtrail_bucket" {
  statement {
    sid       = "AWSCloudTrailAclCheck"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.cloudtrail.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }

  statement {
    sid       = "AWSCloudTrailWrite"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  policy = data.aws_iam_policy_document.cloudtrail_bucket.json
}

resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = "/cloudtrail/cs-account"
  retention_in_days = 90
}

data "aws_iam_policy_document" "cloudtrail_logs_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cloudtrail_logs" {
  name               = "cs-cloudtrail-logs"
  assume_role_policy = data.aws_iam_policy_document.cloudtrail_logs_assume.json
}

resource "aws_iam_role_policy" "cloudtrail_logs" {
  name = "cs-cloudtrail-logs-policy"
  role = aws_iam_role.cloudtrail_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = ["${aws_cloudwatch_log_group.cloudtrail.arn}:*"]
    }]
  })
}

resource "aws_cloudtrail" "this" {
  name                       = "cs-account-trail"
  s3_bucket_name             = aws_s3_bucket.cloudtrail.id
  is_multi_region_trail      = true
  enable_log_file_validation = true
  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail_logs.arn

  depends_on = [aws_s3_bucket_policy.cloudtrail]
}

# --- AWS Config: drift detection, default recorder covering all supported types.

resource "aws_s3_bucket" "config" {
  bucket = "cs-config-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "config" {
  bucket                  = aws_s3_bucket.config.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "config_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "config" {
  name               = "cs-config-recorder"
  assume_role_policy = data.aws_iam_policy_document.config_assume.json
}

resource "aws_iam_role_policy_attachment" "config" {
  role       = aws_iam_role.config.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

data "aws_iam_policy_document" "config_bucket" {
  statement {
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.config.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.config.arn]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
  }
}

resource "aws_s3_bucket_policy" "config" {
  bucket = aws_s3_bucket.config.id
  policy = data.aws_iam_policy_document.config_bucket.json
}

resource "aws_config_configuration_recorder" "this" {
  name     = "cs-config-recorder"
  role_arn = aws_iam_role.config.arn

  recording_group {
    all_supported = true
  }
}

resource "aws_config_delivery_channel" "this" {
  name           = "cs-config-channel"
  s3_bucket_name = aws_s3_bucket.config.id
  depends_on     = [aws_config_configuration_recorder.this, aws_s3_bucket_policy.config]
}

resource "aws_config_configuration_recorder_status" "this" {
  name       = aws_config_configuration_recorder.this.name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.this]
}

# --- GuardDuty: watches VPC Flow Logs, DNS logs, and CloudTrail.

resource "aws_guardduty_detector" "this" {
  enable = true
}

# --- Security Hub: AWS Foundational Security Best Practices standard.

resource "aws_securityhub_account" "this" {}

resource "aws_securityhub_standards_subscription" "foundational" {
  standards_arn = "arn:aws:securityhub:us-east-1::standards/aws-foundational-security-best-practices/v/1.0.0"
  depends_on    = [aws_securityhub_account.this]
}
