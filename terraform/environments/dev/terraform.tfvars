project_name = "geo-ingest-dev"
environment  = "dev"
aws_region   = "us-east-1"
azs          = ["us-east-1a", "us-east-1b"]

db_instance_class        = "db.t3.micro"
db_allocated_storage     = 20
db_multi_az              = false
db_backup_retention_days = 7

log_retention_days = 14
enable_aws_backup  = true
