module "networking" {
  source = "./modules/networking"

  project_name          = var.project_name
  vpc_cidr              = var.vpc_cidr
  public_subnet_cidrs   = var.public_subnet_cidrs
  private_subnet_cidrs  = var.private_subnet_cidrs
  azs                   = var.azs
}

module "security" {
  source = "./modules/security"

  project_name = var.project_name
  vpc_id       = module.networking.vpc_id
}

module "s3" {
  source = "./modules/s3"

  project_name = var.project_name
}

module "rds" {
  source = "./modules/rds"

  project_name           = var.project_name
  private_subnet_ids     = module.networking.private_subnet_ids
  db_security_group_id   = module.security.rds_security_group_id
  db_name                = var.db_name
  db_username            = var.db_username
  instance_class         = var.db_instance_class
  allocated_storage      = var.db_allocated_storage
  multi_az               = var.db_multi_az
  backup_retention_days  = var.db_backup_retention_days
}

module "lambda" {
  source = "./modules/lambda"

  project_name              = var.project_name
  private_subnet_ids        = module.networking.private_subnet_ids
  lambda_security_group_id  = module.security.lambda_security_group_id
  s3_bucket_name            = module.s3.bucket_name
  s3_bucket_arn             = module.s3.bucket_arn
  db_secret_arn             = module.rds.db_secret_arn
  db_endpoint               = module.rds.db_endpoint
  db_name                   = module.rds.db_name
  log_retention_days           = var.log_retention_days
  lambda_source_dir            = "${path.root}/../lambda"
  ingest_reserved_concurrency  = var.ingest_reserved_concurrency
}

module "api_gateway" {
  source = "./modules/api_gateway"

  project_name                = var.project_name
  query_lambda_invoke_arn     = module.lambda.query_function_invoke_arn
  query_lambda_function_name  = module.lambda.query_function_name
  log_retention_days          = var.log_retention_days
}

# ---------------------------------------------------------------------------
# S3 -> Lambda wiring
# Defined at the root (rather than inside the s3 or lambda module) to avoid a
# module dependency cycle: the s3 module doesn't need to know about lambda,
# and the lambda module doesn't need to know about the notification config.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# AWS Backup (bonus: automated periodic backups of the RDS/PostGIS database)
# ---------------------------------------------------------------------------
resource "aws_backup_vault" "this" {
  count = var.enable_aws_backup ? 1 : 0
  name  = "${var.project_name}-backup-vault"
}

resource "aws_backup_plan" "this" {
  count = var.enable_aws_backup ? 1 : 0
  name  = "${var.project_name}-backup-plan"

  rule {
    rule_name         = "daily-rds-backup"
    target_vault_name = aws_backup_vault.this[0].name
    schedule          = "cron(0 5 * * ? *)" # 05:00 UTC daily
    lifecycle {
      delete_after = 30
    }
  }
}

resource "aws_iam_role" "backup" {
  count              = var.enable_aws_backup ? 1 : 0
  name               = "${var.project_name}-aws-backup-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "backup" {
  count      = var.enable_aws_backup ? 1 : 0
  role       = aws_iam_role.backup[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_backup_selection" "rds" {
  count        = var.enable_aws_backup ? 1 : 0
  name         = "${var.project_name}-rds-selection"
  plan_id      = aws_backup_plan.this[0].id
  iam_role_arn = aws_iam_role.backup[0].arn
  resources    = [module.rds.db_instance_arn]
}
