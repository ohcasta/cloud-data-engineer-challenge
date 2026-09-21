# Random suffix keeps the bucket name globally unique across accounts/regions.
resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "ingest" {
  bucket = "${var.project_name}-ingest-${random_id.suffix.hex}"

  tags = {
    Name = "${var.project_name}-ingest-bucket"
  }
}

resource "aws_s3_bucket_versioning" "ingest" {
  bucket = aws_s3_bucket.ingest.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "ingest" {
  bucket = aws_s3_bucket.ingest.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "ingest" {
  bucket = aws_s3_bucket.ingest.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle rule: move raw ingest files to Infrequent Access after 30 days,
# since only the aggregated data in PostgreSQL needs to stay hot.
#
# Toggleable because LocalStack Community's S3 doesn't reliably support the
# read-after-write consistency Terraform's AWS provider waits on when
# creating this resource, causing `terraform apply` to hang until timeout.
# terraform-local/ sets enable_lifecycle_rule = false for that reason; the
# real-AWS root (terraform/) leaves it at the default (true).
resource "aws_s3_bucket_lifecycle_configuration" "ingest" {
  count  = var.enable_lifecycle_rule ? 1 : 0
  bucket = aws_s3_bucket.ingest.id

  rule {
    id     = "archive-raw-data"
    status = "Enabled"

    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
  }
}
