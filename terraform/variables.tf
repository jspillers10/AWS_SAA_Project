############################
# General
############################
variable "aws_region" {
  description = "Region to deploy into."
  type        = string
  default     = "us-east-2"
}

variable "project" {
  description = "Name prefix for every resource."
  type        = string
  default     = "prod-webapp"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "owner" {
  type    = string
  default = "jake-spillers"
}

############################
# Network
############################
variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "azs" {
  description = "Exactly two AZs, index-aligned with the subnet CIDR lists."
  type        = list(string)
  default     = ["us-east-2a", "us-east-2b"]

  validation {
    condition     = length(var.azs) == 2
    error_message = "This design is built for exactly two AZs."
  }
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "db_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.20.0/24", "10.0.21.0/24"]
}

variable "single_nat_gateway" {
  description = "true = one NAT GW (cheaper, loses AZ independence). false = one per AZ like the original build."
  type        = bool
  default     = false
}

variable "enable_flow_logs" {
  type    = bool
  default = true
}

############################
# Compute
############################
variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "asg_min_size" {
  type    = number
  default = 2
}

variable "asg_max_size" {
  type    = number
  default = 6
}

variable "asg_desired_capacity" {
  type    = number
  default = 2
}

variable "cpu_target_value" {
  description = "Target tracking average CPU %."
  type        = number
  default     = 70
}

variable "acm_certificate_arn" {
  description = "Optional ACM cert ARN. When set, adds an HTTPS listener and redirects HTTP to HTTPS."
  type        = string
  default     = ""
}

variable "alb_deletion_protection" {
  type    = bool
  default = true
}

############################
# Database
############################
variable "db_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "db_engine_version" {
  description = "MySQL 8.0 left RDS standard support in July 2026, so default to 8.4 LTS to avoid Extended Support charges."
  type        = string
  default     = "8.4"
}

variable "db_parameter_group_family" {
  type    = string
  default = "mysql8.4"
}

variable "db_allocated_storage" {
  type    = number
  default = 20
}

variable "db_max_allocated_storage" {
  type    = number
  default = 100
}

variable "db_multi_az" {
  type    = bool
  default = true
}

variable "db_backup_retention_days" {
  type    = number
  default = 7
}

variable "db_deletion_protection" {
  type    = bool
  default = true
}

variable "db_skip_final_snapshot" {
  type    = bool
  default = false
}

variable "secret_recovery_window_days" {
  description = "0 lets you destroy/recreate secrets immediately (lab). 7-30 for prod."
  type        = number
  default     = 7
}

############################
# Storage / edge
############################
variable "enable_cloudfront" {
  description = "Front the static assets bucket with CloudFront + OAC."
  type        = bool
  default     = false
}

variable "enable_waf" {
  description = "Attach a WAFv2 web ACL (AWS managed rules + rate limit) to the ALB."
  type        = bool
  default     = true
}

variable "waf_rate_limit" {
  description = "Requests per 5 minutes per source IP before blocking."
  type        = number
  default     = 2000
}

############################
# CI/CD
############################
variable "source_provider" {
  description = "codecommit or github (GitHub uses a CodeConnections connection you approve once in the console)."
  type        = string
  default     = "codecommit"

  validation {
    condition     = contains(["codecommit", "github"], var.source_provider)
    error_message = "source_provider must be codecommit or github."
  }
}

variable "source_branch" {
  type    = string
  default = "main"
}

variable "github_repository" {
  description = "owner/repo, only used when source_provider = github."
  type        = string
  default     = ""
}

############################
# Monitoring
############################
variable "alert_email" {
  description = "Email for SNS alarm notifications. Leave empty to skip the subscription."
  type        = string
  default     = ""
}

variable "rds_connection_alarm_threshold" {
  description = "db.t3.micro max_connections is roughly 60-85, so the original 150 threshold could never fire."
  type        = number
  default     = 50
}
