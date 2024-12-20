locals {
  # Create s3 bucket if it was not provided
  create_s3_bucket = var.s3_enable ? var.s3_bucket == "" : false
  s3_bucket        = var.s3_bucket != "" ? var.s3_bucket : module.s3_bucket.s3_bucket_id
}

module "s3_bucket" {
  create_bucket = local.create_s3_bucket
  source        = "terraform-aws-modules/s3-bucket/aws"
  version       = "4.1.2"

  bucket = "${var.name}-s3"
  tags = merge(local.tags, {
    Name        = "${var.name}-s3",
    Description = "S3 bucket for ${var.fullname}"
  })

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm     = "aws:kms"
        kms_master_key_id = local.kms_key_id
      }
    }
  }

  # allow destroy with objects inside
  force_destroy = true
}
