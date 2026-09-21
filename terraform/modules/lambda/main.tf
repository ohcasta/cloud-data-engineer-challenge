# ---------------------------------------------------------------------------
# Packaging
# ---------------------------------------------------------------------------
data "archive_file" "ingest" {
  type        = "zip"
  source_dir  = "${var.lambda_source_dir}/ingest"
  output_path = "${path.module}/build/ingest.zip"
}

data "archive_file" "query" {
  type        = "zip"
  source_dir  = "${var.lambda_source_dir}/query"
  output_path = "${path.module}/build/query.zip"
}

data "archive_file" "backup" {
  type        = "zip"
  source_dir  = "${var.lambda_source_dir}/backup"
  output_path = "${path.module}/build/backup.zip"
}

# The psycopg2 layer must be built beforehand with lambda/layers/psycopg2/build.sh
# (compiles the C extension for the Lambda Linux runtime). See README.
resource "aws_lambda_layer_version" "psycopg2" {
  layer_name          = "${var.project_name}-psycopg2"
  filename            = "${var.lambda_source_dir}/layers/psycopg2/psycopg2-layer.zip"
  compatible_runtimes = [var.runtime]
  source_code_hash    = filebase64sha256("${var.lambda_source_dir}/layers/psycopg2/psycopg2-layer.zip")
}

# ---------------------------------------------------------------------------
# IAM
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_exec" {
  name               = "${var.project_name}-lambda-exec-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

# Grants ENI create/delete (required to run in a VPC) + CloudWatch Logs.
resource "aws_iam_role_policy_attachment" "vpc_access" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# S3 invokes Lambda asynchronously ("event" invocation type). Async
# invocations retry automatically on failure (twice, by default), and if
# every retry also fails, the event is simply dropped unless an on-failure
# destination is configured. This queue is that destination: it captures
# the event and the failure reason so the file isn't silently lost, and
# gives ops something concrete to alarm on and replay from.
resource "aws_sqs_queue" "ingest_dlq" {
  name                      = "${var.project_name}-ingest-dlq"
  message_retention_seconds = 1209600 # 14 days
}

data "aws_iam_policy_document" "lambda_inline" {
  statement {
    sid       = "ReadIngestBucket"
    actions   = ["s3:GetObject"]
    resources = ["${var.s3_bucket_arn}/*"]
  }

  statement {
    sid       = "ReadDbSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.db_secret_arn]
  }

  statement {
    sid       = "WriteIngestDlq"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.ingest_dlq.arn]
  }

  statement {
    sid       = "WriteBackupExports"
    actions   = ["s3:PutObject"]
    resources = ["${var.s3_bucket_arn}/${var.backup_prefix}*"]
  }
}

resource "aws_iam_role_policy" "lambda_inline" {
  name   = "${var.project_name}-lambda-inline-policy"
  role   = aws_iam_role.lambda_exec.id
  policy = data.aws_iam_policy_document.lambda_inline.json
}

# ---------------------------------------------------------------------------
# CloudWatch Log Groups (created explicitly so retention is enforced)
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "ingest" {
  name              = "/aws/lambda/${var.project_name}-ingest"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "query" {
  name              = "/aws/lambda/${var.project_name}-query"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "backup" {
  name              = "/aws/lambda/${var.project_name}-backup"
  retention_in_days = var.log_retention_days
}

# ---------------------------------------------------------------------------
# Lambda functions
# ---------------------------------------------------------------------------
resource "aws_lambda_function" "ingest" {
  function_name = "${var.project_name}-ingest"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "handler.lambda_handler"
  runtime       = var.runtime
  timeout       = 30
  memory_size   = 256

  # Bounds how many concurrent executions can open a connection to RDS at
  # once. A t3.micro Postgres instance's default max_connections is small
  # (~87); an unbounded burst of S3 uploads could otherwise exhaust it and
  # cause cascading connection failures across both Lambdas. Sized well
  # under that ceiling; raise alongside instance_class/max_connections for
  # higher throughput.
  reserved_concurrent_executions = var.ingest_reserved_concurrency

  filename         = data.archive_file.ingest.output_path
  source_code_hash = data.archive_file.ingest.output_base64sha256
  layers           = [aws_lambda_layer_version.psycopg2.arn]

  dynamic "vpc_config" {
    for_each = var.attach_vpc ? [1] : []
    content {
      subnet_ids         = var.private_subnet_ids
      security_group_ids = [var.lambda_security_group_id]
    }
  }

  environment {
    variables = {
      DB_SECRET_ARN = var.db_secret_arn
      DB_HOST       = var.db_endpoint
      DB_NAME       = var.db_name
    }
  }

  depends_on = [aws_cloudwatch_log_group.ingest, aws_iam_role_policy_attachment.vpc_access]

  tags = {
    Name = "${var.project_name}-ingest"
  }
}

resource "aws_lambda_function" "query" {
  function_name = "${var.project_name}-query"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "handler.lambda_handler"
  runtime       = var.runtime
  timeout       = 15
  memory_size   = 256

  filename         = data.archive_file.query.output_path
  source_code_hash = data.archive_file.query.output_base64sha256
  layers           = [aws_lambda_layer_version.psycopg2.arn]

  dynamic "vpc_config" {
    for_each = var.attach_vpc ? [1] : []
    content {
      subnet_ids         = var.private_subnet_ids
      security_group_ids = [var.lambda_security_group_id]
    }
  }

  environment {
    variables = {
      DB_SECRET_ARN = var.db_secret_arn
      DB_HOST       = var.db_endpoint
      DB_NAME       = var.db_name
    }
  }

  depends_on = [aws_cloudwatch_log_group.query, aws_iam_role_policy_attachment.vpc_access]

  tags = {
    Name = "${var.project_name}-query"
  }
}

resource "aws_lambda_function" "backup" {
  function_name = "${var.project_name}-backup"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "handler.lambda_handler"
  runtime       = var.runtime
  timeout       = 60
  memory_size   = 256

  filename         = data.archive_file.backup.output_path
  source_code_hash = data.archive_file.backup.output_base64sha256
  layers           = [aws_lambda_layer_version.psycopg2.arn]

  dynamic "vpc_config" {
    for_each = var.attach_vpc ? [1] : []
    content {
      subnet_ids         = var.private_subnet_ids
      security_group_ids = [var.lambda_security_group_id]
    }
  }

  environment {
    variables = {
      DB_SECRET_ARN  = var.db_secret_arn
      DB_HOST        = var.db_endpoint
      DB_NAME        = var.db_name
      BACKUP_BUCKET  = var.s3_bucket_name
      BACKUP_PREFIX  = var.backup_prefix
    }
  }

  depends_on = [aws_cloudwatch_log_group.backup, aws_iam_role_policy_attachment.vpc_access]

  tags = {
    Name = "${var.project_name}-backup"
  }
}

# Daily scheduled export of aggregated_data to S3 -- see lambda/backup/handler.py
# for why this exists alongside the AWS Backup RDS snapshot plan (root main.tf).
resource "aws_cloudwatch_event_rule" "daily_backup" {
  name                = "${var.project_name}-daily-backup"
  schedule_expression = var.backup_schedule_expression
}

resource "aws_cloudwatch_event_target" "daily_backup" {
  rule      = aws_cloudwatch_event_rule.daily_backup.name
  target_id = "${var.project_name}-backup-lambda"
  arn       = aws_lambda_function.backup.arn
}

resource "aws_lambda_permission" "allow_eventbridge_invoke_backup" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.backup.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily_backup.arn
}

resource "aws_lambda_function_event_invoke_config" "ingest" {
  function_name                = aws_lambda_function.ingest.function_name
  maximum_retry_attempts       = 2
  maximum_event_age_in_seconds = 3600

  destination_config {
    on_failure {
      destination = aws_sqs_queue.ingest_dlq.arn
    }
  }
}

# ---------------------------------------------------------------------------
# CloudWatch Alarms (bonus: monitoring & alerts)
# ---------------------------------------------------------------------------
resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-lambda-alerts"
}

resource "aws_cloudwatch_metric_alarm" "ingest_errors" {
  alarm_name          = "${var.project_name}-ingest-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Triggers when the ingest Lambda raises any errors"
  dimensions = {
    FunctionName = aws_lambda_function.ingest.function_name
  }
  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "query_errors" {
  alarm_name          = "${var.project_name}-query-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Triggers when the query Lambda raises any errors"
  dimensions = {
    FunctionName = aws_lambda_function.query.function_name
  }
  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "ingest_dlq_not_empty" {
  alarm_name          = "${var.project_name}-ingest-dlq-not-empty"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "A file failed to ingest even after Lambda's automatic retries; it landed in the DLQ for manual investigation/replay"
  dimensions = {
    QueueName = aws_sqs_queue.ingest_dlq.name
  }
  alarm_actions = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "ingest_throttles" {
  alarm_name          = "${var.project_name}-ingest-throttles"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Throttles"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Triggers when the ingest Lambda is throttled"
  dimensions = {
    FunctionName = aws_lambda_function.ingest.function_name
  }
  alarm_actions = [aws_sns_topic.alerts.arn]
}
