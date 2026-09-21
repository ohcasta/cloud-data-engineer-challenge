output "bucket_name" {
  value = module.s3.bucket_name
}

output "ingest_function_name" {
  value = module.lambda.ingest_function_name
}

output "query_function_name" {
  value = module.lambda.query_function_name
}

output "backup_function_name" {
  value = module.lambda.backup_function_name
}

output "ingest_dlq_url" {
  value = module.lambda.ingest_dlq_url
}

output "rest_api_id" {
  value = module.api_gateway.rest_api_id
}

# LocalStack's classic path-style invoke URL. Always works regardless of
# DNS setup (unlike the *.execute-api.localhost.localstack.cloud style,
# which needs the LocalStack DNS trick to resolve).
output "api_endpoint" {
  value = "http://localhost:4566/restapis/${module.api_gateway.rest_api_id}/prod/_user_request_/aggregated-data"
}

# The AWS-provider-computed invoke_url, kept for reference. Under
# LocalStack this often resolves to a real-AWS-style hostname that won't
# work locally -- use `api_endpoint` above instead.
output "invoke_url_raw" {
  value = module.api_gateway.invoke_url
}
