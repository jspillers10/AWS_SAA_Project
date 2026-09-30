# Offline plan tests: no AWS credentials needed.
# Run: terraform test   (Terraform >= 1.7)  or  tofu test

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_elb_service_account" {
    defaults = { arn = "arn:aws:iam::033677994240:root" }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { value = "ami-0123456789abcdef0" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock" }
  }
  mock_resource "aws_iam_instance_profile" {
    defaults = { arn = "arn:aws:iam::123456789012:instance-profile/mock" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-east-2:123456789012:log-group:mock" }
  }
  mock_resource "aws_lb" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-2:123456789012:loadbalancer/app/mock/0123456789abcdef" }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-2:123456789012:targetgroup/mock/0123456789abcdef" }
  }
  mock_resource "aws_wafv2_web_acl" {
    defaults = { arn = "arn:aws:wafv2:us-east-2:123456789012:regional/webacl/mock/00000000-0000-0000-0000-000000000000" }
  }
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:us-east-2:123456789012:mock" }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-east-2:123456789012:secret:mock-AbCdEf" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::mock-bucket" }
  }
  mock_resource "aws_codepipeline" {
    defaults = { arn = "arn:aws:codepipeline:us-east-2:123456789012:mock" }
  }
  mock_resource "aws_codecommit_repository" {
    defaults = { arn = "arn:aws:codecommit:us-east-2:123456789012:mock" }
  }
  mock_resource "aws_codestarconnections_connection" {
    defaults = { arn = "arn:aws:codestar-connections:us-east-2:123456789012:connection/00000000-0000-0000-0000-000000000000" }
  }
  mock_resource "aws_codebuild_project" {
    defaults = { arn = "arn:aws:codebuild:us-east-2:123456789012:project/mock" }
  }
  mock_resource "aws_cloudfront_distribution" {
    defaults = { arn = "arn:aws:cloudfront::123456789012:distribution/EMOCK" }
  }
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0", latest_version = 1 }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

mock_provider "random" {}

variables {
  alert_email = "alerts@example.com"
}

run "defaults_codecommit" {
  command = plan

  assert {
    condition     = length(module.network.private_subnet_ids) == 2
    error_message = "expected 2 private subnets"
  }
}

run "github_cloudfront_https_single_nat" {
  command = plan

  variables {
    source_provider     = "github"
    github_repository   = "jspillers10/prod-webapp"
    enable_cloudfront   = true
    enable_waf          = false
    single_nat_gateway  = true
    acm_certificate_arn = "arn:aws:acm:us-east-2:123456789012:certificate/00000000-0000-0000-0000-000000000000"
  }

  assert {
    condition     = output.app_url != null
    error_message = "app_url missing"
  }
}

run "rejects_bad_source_provider" {
  command = plan

  variables {
    source_provider = "bitbucket"
  }

  expect_failures = [var.source_provider]
}
