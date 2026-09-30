variable "name" { type = string }
variable "enable_cloudfront" { type = bool }

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  buckets = {
    static    = "${var.name}-static-assets-${random_id.suffix.hex}"
    logs      = "${var.name}-logs-${random_id.suffix.hex}"
    artifacts = "${var.name}-pipeline-artifacts-${random_id.suffix.hex}"
  }
}

data "aws_elb_service_account" "this" {}

############################
# Common bucket hardening
############################
resource "aws_s3_bucket" "this" {
  for_each      = local.buckets
  bucket        = each.value
  force_destroy = true # lab-friendly teardown; flip to false for real prod
}

resource "aws_s3_bucket_ownership_controls" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each                = aws_s3_bucket.this
  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# SSE-S3 everywhere (ALB access logs only support SSE-S3 anyway)
resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = { for k, v in aws_s3_bucket.this : k => v if k != "logs" }
  bucket   = each.value.id
  versioning_configuration {
    status = "Enabled"
  }
}

data "aws_iam_policy_document" "tls_only" {
  for_each = aws_s3_bucket.this
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      each.value.arn,
      "${each.value.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

############################
# Lifecycle rules (match the console build)
############################
resource "aws_s3_bucket_lifecycle_configuration" "static" {
  bucket = aws_s3_bucket.this["static"].id
  rule {
    id     = "to-ia-after-90d"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.this["logs"].id
  rule {
    id     = "expire-90d"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
    expiration {
      days = 90
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.this["artifacts"].id
  rule {
    id     = "expire-noncurrent-30d"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
  depends_on = [aws_s3_bucket_versioning.this]
}

# Static bucket access logs -> logs bucket
resource "aws_s3_bucket_logging" "static" {
  bucket        = aws_s3_bucket.this["static"].id
  target_bucket = aws_s3_bucket.this["logs"].id
  target_prefix = "s3/static-assets/"
}

############################
# Bucket policies
############################
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "logs" {
  source_policy_documents = [data.aws_iam_policy_document.tls_only["logs"].json]

  statement {
    sid       = "ALBAccessLogs"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.this["logs"].arn}/alb/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.this.arn]
    }
  }

  statement {
    sid       = "S3ServerAccessLogs"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.this["logs"].arn}/s3/*"]
    principals {
      type        = "Service"
      identifiers = ["logging.s3.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_s3_bucket_policy" "logs" {
  bucket     = aws_s3_bucket.this["logs"].id
  policy     = data.aws_iam_policy_document.logs.json
  depends_on = [aws_s3_bucket_public_access_block.this]
}

resource "aws_s3_bucket_policy" "artifacts" {
  bucket     = aws_s3_bucket.this["artifacts"].id
  policy     = data.aws_iam_policy_document.tls_only["artifacts"].json
  depends_on = [aws_s3_bucket_public_access_block.this]
}

data "aws_iam_policy_document" "static" {
  source_policy_documents = [data.aws_iam_policy_document.tls_only["static"].json]

  dynamic "statement" {
    for_each = var.enable_cloudfront ? [1] : []
    content {
      sid       = "AllowCloudFrontOAC"
      actions   = ["s3:GetObject"]
      resources = ["${aws_s3_bucket.this["static"].arn}/*"]
      principals {
        type        = "Service"
        identifiers = ["cloudfront.amazonaws.com"]
      }
      condition {
        test     = "StringEquals"
        variable = "AWS:SourceArn"
        values   = [aws_cloudfront_distribution.static[0].arn]
      }
    }
  }
}

resource "aws_s3_bucket_policy" "static" {
  bucket     = aws_s3_bucket.this["static"].id
  policy     = data.aws_iam_policy_document.static.json
  depends_on = [aws_s3_bucket_public_access_block.this]
}

############################
# CloudFront + OAC (replaces the legacy OAI in the original design)
############################
resource "aws_cloudfront_origin_access_control" "static" {
  count                             = var.enable_cloudfront ? 1 : 0
  name                              = "${var.name}-static-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "static" {
  count               = var.enable_cloudfront ? 1 : 0
  enabled             = true
  comment             = "${var.name} static assets"
  price_class         = "PriceClass_100"
  http_version        = "http2and3"
  is_ipv6_enabled     = true
  default_root_object = "index.html"

  origin {
    origin_id                = "static-s3"
    domain_name              = aws_s3_bucket.this["static"].bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.static[0].id
  }

  default_cache_behavior {
    target_origin_id       = "static-s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6" # Managed-CachingOptimized
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

############################
# Outputs
############################
output "static_bucket_name" { value = aws_s3_bucket.this["static"].id }
output "static_bucket_arn" { value = aws_s3_bucket.this["static"].arn }
output "artifacts_bucket_name" { value = aws_s3_bucket.this["artifacts"].id }
output "artifacts_bucket_arn" { value = aws_s3_bucket.this["artifacts"].arn }

# Referencing the policy resource makes the ALB wait until log delivery is allowed.
output "logs_bucket_name" { value = aws_s3_bucket_policy.logs.bucket }

output "cloudfront_domain" {
  value = var.enable_cloudfront ? aws_cloudfront_distribution.static[0].domain_name : null
}
