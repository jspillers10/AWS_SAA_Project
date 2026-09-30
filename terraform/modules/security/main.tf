variable "name" { type = string }
variable "vpc_id" { type = string }
variable "vpc_cidr" { type = string }

# Rules are separate resources so SGs can reference each other without cycles.

############################
# alb-sg
############################
resource "aws_security_group" "alb" {
  name        = "alb-sg"
  description = "Internet-facing ALB"
  vpc_id      = var.vpc_id
  tags        = { Name = "alb-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from internet"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from internet"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "HTTP to app tier only"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

############################
# app-sg
############################
resource "aws_security_group" "app" {
  name        = "app-sg"
  description = "Web/app instances"
  vpc_id      = var.vpc_id
  tags        = { Name = "app-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "HTTP from ALB only"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

# No SSH rule: shell access is via SSM Session Manager.

resource "aws_vpc_security_group_egress_rule" "app_https" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS out via NAT (dnf, SSM, CodeDeploy, Secrets Manager, S3)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "app_to_rds" {
  security_group_id            = aws_security_group.app.id
  description                  = "MySQL to RDS"
  referenced_security_group_id = aws_security_group.rds.id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
}

############################
# rds-sg
############################
resource "aws_security_group" "rds" {
  name        = "rds-sg"
  description = "RDS MySQL"
  vpc_id      = var.vpc_id
  tags        = { Name = "rds-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_app" {
  security_group_id            = aws_security_group.rds.id
  description                  = "MySQL from app tier"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_codebuild" {
  security_group_id            = aws_security_group.rds.id
  description                  = "MySQL from migration CodeBuild"
  referenced_security_group_id = aws_security_group.codebuild.id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
}

# No egress rules on rds-sg. Terraform strips AWS's default allow-all egress
# rule when it creates a VPC security group, so this group has zero egress.

############################
# codebuild-sg (DB migration job runs inside the VPC)
############################
resource "aws_security_group" "codebuild" {
  name        = "codebuild-migrate-sg"
  description = "CodeBuild DB migration project"
  vpc_id      = var.vpc_id
  tags        = { Name = "codebuild-migrate-sg" }
}

resource "aws_vpc_security_group_egress_rule" "codebuild_https" {
  security_group_id = aws_security_group.codebuild.id
  description       = "HTTPS out (pip, Secrets Manager, S3, logs)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "codebuild_to_rds" {
  security_group_id            = aws_security_group.codebuild.id
  description                  = "MySQL to RDS"
  referenced_security_group_id = aws_security_group.rds.id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
}

output "alb_sg_id" { value = aws_security_group.alb.id }
output "app_sg_id" { value = aws_security_group.app.id }
output "rds_sg_id" { value = aws_security_group.rds.id }
output "codebuild_sg_id" { value = aws_security_group.codebuild.id }
