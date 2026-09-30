output "app_url" {
  value = var.acm_certificate_arn == "" ? "http://${module.compute.alb_dns_name}" : "https://${module.compute.alb_dns_name}"
}

output "alb_dns_name" {
  value = module.compute.alb_dns_name
}

output "rds_endpoint" {
  value = module.database.endpoint
}

output "db_master_secret_arn" {
  value = module.database.master_secret_arn
}

output "db_app_secret_arn" {
  value = module.database.app_secret_arn
}

output "codecommit_clone_url_http" {
  description = "Push the app/ folder here to kick off the pipeline (codecommit only)."
  value       = module.cicd.codecommit_clone_url_http
}

output "github_connection_arn" {
  description = "Approve this connection in the console once (github only)."
  value       = module.cicd.github_connection_arn
}

output "pipeline_name" {
  value = module.cicd.pipeline_name
}

output "static_assets_bucket" {
  value = module.storage.static_bucket_name
}

output "cloudfront_domain" {
  value = module.storage.cloudfront_domain
}

output "sns_topic_arn" {
  value = module.monitoring.sns_topic_arn
}

output "dashboard_url" {
  value = module.monitoring.dashboard_url
}
