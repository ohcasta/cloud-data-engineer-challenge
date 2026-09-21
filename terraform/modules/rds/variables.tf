variable "project_name" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "db_security_group_id" {
  type = string
}

variable "db_name" {
  type    = string
  default = "geodata"
}

variable "db_username" {
  type    = string
  default = "geoadmin"
}

variable "instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "allocated_storage" {
  type    = number
  default = 20
}

variable "multi_az" {
  type    = bool
  default = false
}

variable "backup_retention_days" {
  type    = number
  default = 7
}

variable "engine_version" {
  description = "PostgreSQL engine version. Must be one that ships the postgis extension (all modern RDS Postgres versions do)."
  type        = string
  default     = "16.4"
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "skip_final_snapshot" {
  description = "Set to false for production so a final snapshot is taken on destroy."
  type        = bool
  default     = true
}
