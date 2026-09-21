variable "project_name" {
  description = "Prefix applied to all resource names"
  type        = string
  default     = "geo-ingest"
}

variable "environment" {
  description = "Deployment environment label (dev/staging/prod)"
  type        = string
  default     = "dev"
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "azs" {
  description = "Availability zones to use (must have at least 2)"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "db_name" {
  type    = string
  default = "geodata"
}

variable "db_username" {
  type    = string
  default = "geoadmin"
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "db_allocated_storage" {
  type    = number
  default = 20
}

variable "db_multi_az" {
  type    = bool
  default = false
}

variable "db_backup_retention_days" {
  type    = number
  default = 7
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "enable_aws_backup" {
  description = "Whether to create an AWS Backup plan for the RDS instance (bonus: automated backups)"
  type        = bool
  default     = true
}

variable "ingest_reserved_concurrency" {
  description = "Max concurrent ingest Lambda executions, to bound simultaneous RDS connections"
  type        = number
  default     = 10
}
