resource "aws_kms_key" "state" {
  policy                  = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { AWS = "arn:aws:iam::${var.account_id}:root" }, Action = "kms:*", Resource = "*" }] })
  enable_key_rotation     = true
  deletion_window_in_days = 30
  description             = "Terraform state encryption"
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket" "state" {
  #checkov:skip=CKV2_AWS_62:CloudTrail data events and S3 access logs provide audit; no object event consumer exists.
  #checkov:skip=CKV_AWS_144:State recoverability uses same-region versioning; cross-region DR is not a requirement.
  bucket        = var.bucket_name
  force_destroy = false
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Deny", Principal = "*", Action = "s3:*", Resource = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"], Condition = { Bool = { "aws:SecureTransport" = "false" } } }, { Effect = "Deny", Principal = "*", Action = "s3:*", Resource = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"], Condition = { StringNotEquals = { "aws:PrincipalAccount" = var.account_id } } }] })
}

resource "aws_ecr_repository" "artifacts" {
  name                 = "platform-artifacts"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.state.arn
  }
}

output "bucket" {
  value = aws_s3_bucket.state.id
}

output "kms_key_arn" {
  value = aws_kms_key.state.arn
}

output "artifact_repository" {
  value = aws_ecr_repository.artifacts.repository_url
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "retain-state-history"
    status = "Enabled"
    filter { prefix = "" }
    noncurrent_version_expiration { noncurrent_days = 365 }
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }
}
