variable "project_name" {
  type = string
}

variable "enable_lifecycle_rule" {
  description = "Whether to create the S3 lifecycle transition rule. Set false for LocalStack (see main.tf comment)."
  type        = bool
  default     = true
}
