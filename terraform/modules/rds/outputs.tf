output "db_endpoint" {
  value = aws_db_instance.postgis.address
}

output "db_port" {
  value = aws_db_instance.postgis.port
}

output "db_name" {
  value = aws_db_instance.postgis.db_name
}

output "db_instance_arn" {
  value = aws_db_instance.postgis.arn
}

output "db_secret_arn" {
  value = aws_secretsmanager_secret.db_credentials.arn
}
