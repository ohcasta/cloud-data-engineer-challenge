variable "project_name" {
  type = string
}

variable "query_lambda_invoke_arn" {
  type = string
}

variable "query_lambda_function_name" {
  type = string
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "stage_name" {
  type    = string
  default = "prod"
}
