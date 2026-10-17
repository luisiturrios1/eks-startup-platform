resource "aws_s3_bucket" "audit" {
  #checkov:skip=CKV2_AWS_62:Audit destination has no object event consumer.
  #checkov:skip=CKV_AWS_144:Single-region audit retention with versioning.
  #checkov:skip=CKV_AWS_145:S3 server access log destination uses SSE-S3; CloudTrail objects additionally use the explicit KMS key.
  bucket        = "${var.bucket_name}-audit"
  force_destroy = false
  lifecycle { prevent_destroy = true }
}
resource "aws_s3_bucket_public_access_block" "audit" {
  bucket                  = aws_s3_bucket.audit.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_versioning" "audit" {
  bucket = aws_s3_bucket.audit.id
  versioning_configuration { status = "Enabled" }
}
# trivy:ignore:AVD-AWS-0132:exp:2027-01-16 -- SSE-S3 access-log destination; CloudTrail objects additionally use KMS. See docs/security-exceptions.md.
resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}
resource "aws_s3_bucket_lifecycle_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id
  rule {
    id     = "audit-retention"
    status = "Enabled"
    filter { prefix = "" }
    expiration { days = 365 }
    noncurrent_version_expiration { noncurrent_days = 90 }
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }
}
resource "aws_s3_bucket_logging" "state" {
  bucket        = aws_s3_bucket.state.id
  target_bucket = aws_s3_bucket.audit.id
  target_prefix = "state-access/"
}
resource "aws_s3_bucket_policy" "audit" {
  bucket = aws_s3_bucket.audit.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Deny", Principal = "*", Action = "s3:*", Resource = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"], Condition = { Bool = { "aws:SecureTransport" = "false" } } },
    { Effect = "Allow", Principal = { Service = "logging.s3.amazonaws.com" }, Action = "s3:PutObject", Resource = "${aws_s3_bucket.audit.arn}/state-access/*", Condition = { StringEquals = { "aws:SourceAccount" = var.account_id } } },
    { Effect = "Allow", Principal = { Service = "cloudtrail.amazonaws.com" }, Action = "s3:GetBucketAcl", Resource = aws_s3_bucket.audit.arn, Condition = { StringEquals = { "aws:SourceArn" = "arn:aws:cloudtrail:${var.region}:${var.account_id}:trail/platform-audit" } } },
    { Effect = "Allow", Principal = { Service = "cloudtrail.amazonaws.com" }, Action = "s3:PutObject", Resource = "${aws_s3_bucket.audit.arn}/trail/AWSLogs/${var.account_id}/*", Condition = { StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control", "aws:SourceArn" = "arn:aws:cloudtrail:${var.region}:${var.account_id}:trail/platform-audit" } } }
  ] })
}
resource "aws_kms_key" "audit" {
  description             = "CloudTrail encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "logs.${var.region}.amazonaws.com" }, Action = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"], Resource = "*", Condition = { ArnLike = { "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${var.region}:${var.account_id}:log-group:/platform/audit" } } },
    { Effect = "Allow", Principal = { AWS = "arn:aws:iam::${var.account_id}:root" }, Action = "kms:*", Resource = "*" },
    { Effect = "Allow", Principal = { Service = "cloudtrail.amazonaws.com" }, Action = ["kms:GenerateDataKey*", "kms:DescribeKey"], Resource = "*", Condition = { StringEquals = { "aws:SourceArn" = "arn:aws:cloudtrail:${var.region}:${var.account_id}:trail/platform-audit" } } }
  ] })
}
resource "aws_cloudtrail" "platform" {
  #checkov:skip=CKV_AWS_252:CloudWatch Logs provides audit collection; SNS file delivery notifications are not required.
  cloud_watch_logs_group_arn    = "${aws_cloudwatch_log_group.audit.arn}:*"
  cloud_watch_logs_role_arn     = aws_iam_role.audit.arn
  name                          = "platform-audit"
  s3_bucket_name                = aws_s3_bucket.audit.id
  s3_key_prefix                 = "trail"
  kms_key_id                    = aws_kms_key.audit.arn
  enable_logging                = true
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  event_selector {
    read_write_type           = "All"
    include_management_events = true
    data_resource {
      type   = "AWS::S3::Object"
      values = ["${aws_s3_bucket.state.arn}/"]
    }
  }
  depends_on = [aws_s3_bucket_policy.audit]
}

resource "aws_cloudwatch_log_group" "audit" {
  name              = "/platform/audit"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.audit.arn
}
resource "aws_iam_role" "audit" {
  name               = "platform-cloudtrail"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "cloudtrail.amazonaws.com" }, Action = "sts:AssumeRole" }] })
}
resource "aws_iam_role_policy" "audit" {
  role   = aws_iam_role.audit.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.audit.arn}:*" }] })
}
