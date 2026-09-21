output "bucket_id" {
  value = aws_s3_bucket.ingest.id
}

output "bucket_arn" {
  value = aws_s3_bucket.ingest.arn
}

output "bucket_name" {
  value = aws_s3_bucket.ingest.bucket
}
