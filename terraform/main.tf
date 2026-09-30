locals {
  name = var.project
}

module "network" {
  source = "./modules/network"

  name                 = local.name
  vpc_cidr             = var.vpc_cidr
  azs                  = var.azs
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  db_subnet_cidrs      = var.db_subnet_cidrs
  single_nat_gateway   = var.single_nat_gateway
  enable_flow_logs     = var.enable_flow_logs
}

module "security" {
  source = "./modules/security"

  name     = local.name
  vpc_id   = module.network.vpc_id
  vpc_cidr = var.vpc_cidr
}

module "storage" {
  source = "./modules/storage"

  name              = local.name
  enable_cloudfront = var.enable_cloudfront
}

module "database" {
  source = "./modules/database"

  name                        = local.name
  db_subnet_ids               = module.network.db_subnet_ids
  rds_sg_id                   = module.security.rds_sg_id
  instance_class              = var.db_instance_class
  engine_version              = var.db_engine_version
  parameter_group_family      = var.db_parameter_group_family
  allocated_storage           = var.db_allocated_storage
  max_allocated_storage       = var.db_max_allocated_storage
  multi_az                    = var.db_multi_az
  backup_retention_days       = var.db_backup_retention_days
  deletion_protection         = var.db_deletion_protection
  skip_final_snapshot         = var.db_skip_final_snapshot
  secret_recovery_window_days = var.secret_recovery_window_days
}

module "compute" {
  source = "./modules/compute"

  name                    = local.name
  aws_region              = var.aws_region
  vpc_id                  = module.network.vpc_id
  public_subnet_ids       = module.network.public_subnet_ids
  private_subnet_ids      = module.network.private_subnet_ids
  alb_sg_id               = module.security.alb_sg_id
  app_sg_id               = module.security.app_sg_id
  instance_type           = var.instance_type
  min_size                = var.asg_min_size
  max_size                = var.asg_max_size
  desired_capacity        = var.asg_desired_capacity
  cpu_target_value        = var.cpu_target_value
  acm_certificate_arn     = var.acm_certificate_arn
  alb_deletion_protection = var.alb_deletion_protection
  app_secret_arn          = module.database.app_secret_arn
  static_bucket_arn       = module.storage.static_bucket_arn
  artifacts_bucket_arn    = module.storage.artifacts_bucket_arn
  logs_bucket_name        = module.storage.logs_bucket_name
}

module "waf" {
  source = "./modules/waf"
  count  = var.enable_waf ? 1 : 0

  name       = local.name
  alb_arn    = module.compute.alb_arn
  rate_limit = var.waf_rate_limit
}

module "cicd" {
  source = "./modules/cicd"

  name                 = local.name
  aws_region           = var.aws_region
  source_provider      = var.source_provider
  source_branch        = var.source_branch
  github_repository    = var.github_repository
  artifacts_bucket     = module.storage.artifacts_bucket_name
  artifacts_bucket_arn = module.storage.artifacts_bucket_arn
  vpc_id               = module.network.vpc_id
  private_subnet_ids   = module.network.private_subnet_ids
  codebuild_sg_id      = module.security.codebuild_sg_id
  master_secret_arn    = module.database.master_secret_arn
  app_secret_arn       = module.database.app_secret_arn
  asg_name             = module.compute.asg_name
  target_group_name    = module.compute.target_group_name
  instance_role_arn    = module.compute.instance_role_arn
}

module "monitoring" {
  source = "./modules/monitoring"

  name                     = local.name
  aws_region               = var.aws_region
  alert_email              = var.alert_email
  alb_arn_suffix           = module.compute.alb_arn_suffix
  target_group_arn_suffix  = module.compute.target_group_arn_suffix
  asg_name                 = module.compute.asg_name
  db_instance_id           = module.database.db_instance_id
  rds_connection_threshold = var.rds_connection_alarm_threshold
}
