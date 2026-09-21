variable "project_name" {
  type    = string
  default = "geo-ingest-local"
}

variable "log_retention_days" {
  type    = number
  default = 3
}

# Must match docker-compose.yml's postgis service credentials/hostname --
# there is no real RDS instance in this local stack (RDS/AWS Backup are
# LocalStack Pro-only features). "postgis" resolves because LocalStack's
# Lambda containers join the same Docker network as the postgis container
# (see LAMBDA_DOCKER_NETWORK in docker-compose.yml).
variable "db_host" {
  type    = string
  default = "postgis"
}

variable "db_name" {
  type    = string
  default = "geodata"
}

variable "db_username" {
  type    = string
  default = "geoadmin"
}

variable "db_password" {
  type      = string
  default   = "localdevpassword"
  sensitive = true
}
