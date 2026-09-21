variable "project_name" {
  type = string
}

variable "private_subnet_ids" {
  type    = list(string)
  default = []
}

variable "lambda_security_group_id" {
  type    = string
  default = null
}

variable "s3_bucket_name" {
  type = string
}

variable "s3_bucket_arn" {
  type = string
}

variable "db_secret_arn" {
  type = string
}

variable "db_endpoint" {
  type = string
}

variable "db_name" {
  type = string
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "lambda_source_dir" {
  description = "Path to the repo's lambda/ directory (contains ingest/, query/, layers/)"
  type        = string
}

variable "runtime" {
  type    = string
  default = "python3.12"
}

variable "ingest_reserved_concurrency" {
  description = "Max concurrent ingest Lambda executions, to bound simultaneous RDS connections"
  type        = number
  default     = 10
}

variable "backup_prefix" {
  description = "S3 key prefix the backup Lambda writes CSV exports of aggregated_data to"
  type        = string
  default     = "backups/"
}

variable "backup_schedule_expression" {
  description = "EventBridge schedule expression for the backup Lambda"
  type        = string
  default     = "cron(0 6 * * ? *)" # 06:00 UTC daily
}

variable "attach_vpc" {
  description = "Whether to attach the Lambda functions to the given VPC subnets/security group. Set false for local testing against LocalStack, which does not emulate real VPC-constrained networking."
  type        = bool
  default     = true
}
