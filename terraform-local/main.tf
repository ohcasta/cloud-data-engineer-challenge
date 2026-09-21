# ---------------------------------------------------------------------------
# What this deploys against LocalStack, reusing the SAME Terraform modules
# and the SAME Lambda source code as terraform/ (the real-AWS root):
#   - S3 ingest bucket + notification (../terraform/modules/s3)
#   - Ingest / query / backup Lambdas (../terraform/modules/lambda, with
#     attach_vpc = false since LocalStack doesn't emulate real VPC-scoped
#     networking -- the Lambda containers already share a Docker network
#     with `postgis`, so no VPC hop is needed to reach it)
#   - API Gateway GET /aggregated-data (../terraform/modules/api_gateway)
#
# What's intentionally swapped out for local testing:
#   - No RDS instance -- `db_host` points straight at the docker-compose
#     `postgis` service. RDS is a LocalStack Pro feature.
#   - No AWS Backup plan -- also Pro-only, and moot against a container
#     that docker-compose already persists via a named volume.
#   - No VPC/subnets/NAT/security groups -- LocalStack doesn't enforce real
#     network isolation, so standing up that module here would deploy fake
#     resources without testing anything.
#
# Everything else (S3 event trigger wiring, IAM policies, the DLQ/on-failure
# destination, the API Gateway contract, the aggregation logic itself) is
# exercised for real.
# ---------------------------------------------------------------------------

resource "random_id" "suffix" {
  byte_length = 4
}

module "s3" {
  source = "../terraform/modules/s3"

  project_name           = var.project_name
  enable_lifecycle_rule  = false
}

# The Lambda module normally reads the DB endpoint/secret from the rds
# module's outputs. Locally, there's no rds module -- so this secret and
# these local values stand in for it directly.
resource "aws_secretsmanager_secret" "db_credentials" {
  name        = "${var.project_name}/rds/credentials"
  description = "Local stand-in for the RDS master credentials"
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username = var.db_username
    password = var.db_password
  })
}

module "lambda" {
  source = "../terraform/modules/lambda"

  project_name       = var.project_name
  attach_vpc         = false
  private_subnet_ids = []
  # lambda_security_group_id intentionally omitted (defaults to null); it's
  # unused when attach_vpc = false.

  s3_bucket_name = module.s3.bucket_name
  s3_bucket_arn  = module.s3.bucket_arn
  db_secret_arn  = aws_secretsmanager_secret.db_credentials.arn
  db_endpoint    = var.db_host
  db_name        = var.db_name

  log_retention_days           = var.log_retention_days
  lambda_source_dir            = "${path.module}/../lambda"
  ingest_reserved_concurrency  = 5
}

module "api_gateway" {
  source = "../terraform/modules/api_gateway"

  project_name                = var.project_name
  query_lambda_invoke_arn     = module.lambda.query_function_invoke_arn
  query_lambda_function_name  = module.lambda.query_function_name
  log_retention_days          = var.log_retention_days
}

resource "aws_lambda_permission" "allow_s3_invoke" {
  statement_id  = "AllowExecutionFromS3Bucket"
  action        = "lambda:InvokeFunction"
  function_name = module.lambda.ingest_function_name
  principal     = "s3.amazonaws.com"
  source_arn    = module.s3.bucket_arn
}

resource "aws_s3_bucket_notification" "ingest_trigger" {
  bucket = module.s3.bucket_id

  lambda_function {
    lambda_function_arn = module.lambda.ingest_function_arn
    events              = ["s3:ObjectCreated:Put"]
    filter_prefix       = "raw-data/"
    filter_suffix       = ".csv"
  }

  depends_on = [aws_lambda_permission.allow_s3_invoke]
}
