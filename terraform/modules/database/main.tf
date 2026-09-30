variable "name" { type = string }
variable "db_subnet_ids" { type = list(string) }
variable "rds_sg_id" { type = string }
variable "instance_class" { type = string }
variable "engine_version" { type = string }
variable "parameter_group_family" { type = string }
variable "allocated_storage" { type = number }
variable "max_allocated_storage" { type = number }
variable "multi_az" { type = bool }
variable "backup_retention_days" { type = number }
variable "deletion_protection" { type = bool }
variable "skip_final_snapshot" { type = bool }
variable "secret_recovery_window_days" { type = number }

locals {
  db_name     = "webapp_prod"
  master_user = "dbadmin"
  app_user    = "webapp_user"
  # RDS rejects / @ " and space in passwords
  pw_special = "!#$%^&*()-_=+[]{}<>:?"
}

############################
# Credentials -> Secrets Manager (nothing in user data or code)
############################
resource "random_password" "master" {
  length           = 32
  special          = true
  override_special = local.pw_special
}

resource "random_password" "app" {
  length           = 32
  special          = true
  override_special = local.pw_special
}

# Master creds: only the in-VPC migration CodeBuild job can read this.
resource "aws_secretsmanager_secret" "master" {
  name                    = "${var.name}/db/master"
  description             = "RDS master credentials (migrations only)"
  recovery_window_in_days = var.secret_recovery_window_days
}

resource "aws_secretsmanager_secret_version" "master" {
  secret_id = aws_secretsmanager_secret.master.id
  secret_string = jsonencode({
    username = local.master_user
    password = random_password.master.result
    host     = aws_db_instance.this.address
    port     = aws_db_instance.this.port
    dbname   = local.db_name
  })
}

# App creds: least-privilege DML user, readable by EC2 instances.
resource "aws_secretsmanager_secret" "app" {
  name                    = "${var.name}/db/app"
  description             = "Application DB user (SELECT/INSERT/UPDATE/DELETE on ${local.db_name})"
  recovery_window_in_days = var.secret_recovery_window_days
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id = aws_secretsmanager_secret.app.id
  secret_string = jsonencode({
    username = local.app_user
    password = random_password.app.result
    host     = aws_db_instance.this.address
    port     = aws_db_instance.this.port
    dbname   = local.db_name
  })
}

############################
# RDS
############################
resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-db-subnet-group"
  subnet_ids = var.db_subnet_ids
}

resource "aws_db_parameter_group" "this" {
  name   = "${var.name}-mysql"
  family = var.parameter_group_family

  # Force TLS for every client connection
  parameter {
    name  = "require_secure_transport"
    value = "1"
  }

  parameter {
    name  = "slow_query_log"
    value = "1"
  }

  parameter {
    name  = "long_query_time"
    value = "2"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "this" {
  identifier     = "${var.name}-db"
  engine         = "mysql"
  engine_version = var.engine_version
  instance_class = var.instance_class

  db_name  = local.db_name
  username = local.master_user
  password = random_password.master.result

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  multi_az               = var.multi_az
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.rds_sg_id]
  publicly_accessible    = false
  parameter_group_name   = aws_db_parameter_group.this.name

  backup_retention_period = var.backup_retention_days
  backup_window           = "03:00-04:00"
  maintenance_window      = "mon:04:00-mon:05:00"
  copy_tags_to_snapshot   = true

  enabled_cloudwatch_logs_exports = ["error", "general", "slowquery"]
  auto_minor_version_upgrade      = true

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name}-db-final"

  tags = { Name = "${var.name}-db" }
}

output "db_instance_id" { value = aws_db_instance.this.identifier }
output "endpoint" { value = aws_db_instance.this.endpoint }
output "master_secret_arn" { value = aws_secretsmanager_secret.master.arn }
output "app_secret_arn" { value = aws_secretsmanager_secret.app.arn }
