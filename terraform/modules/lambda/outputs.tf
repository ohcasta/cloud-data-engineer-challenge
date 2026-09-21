output "ingest_function_arn" {
  value = aws_lambda_function.ingest.arn
}

output "ingest_function_name" {
  value = aws_lambda_function.ingest.function_name
}

output "query_function_arn" {
  value = aws_lambda_function.query.arn
}

output "query_function_name" {
  value = aws_lambda_function.query.function_name
}

output "query_function_invoke_arn" {
  value = aws_lambda_function.query.invoke_arn
}

output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "ingest_dlq_url" {
  value = aws_sqs_queue.ingest_dlq.id
}

output "ingest_dlq_arn" {
  value = aws_sqs_queue.ingest_dlq.arn
}

output "backup_function_name" {
  value = aws_lambda_function.backup.function_name
}

output "backup_function_arn" {
  value = aws_lambda_function.backup.arn
}
