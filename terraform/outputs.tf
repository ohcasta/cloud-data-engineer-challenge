output "vpc_id" {
  value = module.networking.vpc_id
}

output "s3_bucket_name" {
  description = "Upload data files here to trigger the pipeline"
  value       = module.s3.bucket_name
}

output "rds_endpoint" {
  value     = module.rds.db_endpoint
  sensitive = false
}

output "db_secret_arn" {
  description = "Secrets Manager ARN holding the DB master credentials"
  value       = module.rds.db_secret_arn
}

output "ingest_lambda_name" {
  value = module.lambda.ingest_function_name
}

output "query_lambda_name" {
  value = module.lambda.query_function_name
}

output "api_endpoint" {
  description = "GET this URL to retrieve aggregated data, e.g. curl \"$(terraform output -raw api_endpoint)?limit=10\""
  value       = module.api_gateway.invoke_url
}

output "alerts_topic_arn" {
  value = module.lambda.alerts_topic_arn
}

output "ingest_dlq_url" {
  description = "SQS queue holding events for files that failed to ingest even after Lambda's automatic retries"
  value       = module.lambda.ingest_dlq_url
}
