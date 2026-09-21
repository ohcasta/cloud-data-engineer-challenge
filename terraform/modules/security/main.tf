resource "aws_security_group" "lambda" {
  name        = "${var.project_name}-lambda-sg"
  description = "Security group for Lambda functions running in private subnets"
  vpc_id      = var.vpc_id

  egress {
    description = "Allow all outbound traffic (internet via NAT, AWS APIs, RDS)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-lambda-sg"
  }
}

# RDS only accepts connections from the Lambda security group on the
# PostgreSQL port. No direct internet or public access.
resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "Security group for the PostgreSQL/PostGIS RDS instance"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Allow PostgreSQL from Lambda functions"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }

  egress {
    description = "Allow all outbound (patching, extensions, etc.)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-rds-sg"
  }
}
