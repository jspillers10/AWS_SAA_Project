variable "name" { type = string }
variable "aws_region" { type = string }
variable "source_provider" { type = string }
variable "source_branch" { type = string }
variable "github_repository" { type = string }
variable "artifacts_bucket" { type = string }
variable "artifacts_bucket_arn" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "codebuild_sg_id" { type = string }
variable "master_secret_arn" { type = string }
variable "app_secret_arn" { type = string }
variable "asg_name" { type = string }
variable "target_group_name" { type = string }
variable "instance_role_arn" { type = string }

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id    = data.aws_caller_identity.current.account_id
  is_codecommit = var.source_provider == "codecommit"
}

############################
# Source
############################
resource "aws_codecommit_repository" "this" {
  count           = local.is_codecommit ? 1 : 0
  repository_name = var.name
  description     = "Production web application source code"
  default_branch  = var.source_branch
}

resource "aws_codestarconnections_connection" "github" {
  count         = local.is_codecommit ? 0 : 1
  name          = "${var.name}-github"
  provider_type = "GitHub"
}

############################
# CodeBuild: shared bits
############################
data "aws_iam_policy_document" "codebuild_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "codebuild_base" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${local.account_id}:log-group:/aws/codebuild/${var.name}-*"]
  }

  statement {
    sid       = "Artifacts"
    actions   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:GetBucketLocation"]
    resources = [var.artifacts_bucket_arn, "${var.artifacts_bucket_arn}/*"]
  }
}

############################
# CodeBuild: lint + package (no AWS access beyond artifacts)
############################
resource "aws_iam_role" "build" {
  name               = "codebuild-webapp-role"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume.json
}

resource "aws_iam_role_policy" "build" {
  name   = "codebuild-build"
  role   = aws_iam_role.build.id
  policy = data.aws_iam_policy_document.codebuild_base.json
}

resource "aws_cloudwatch_log_group" "build" {
  name              = "/aws/codebuild/${var.name}-build"
  retention_in_days = 30
}

resource "aws_codebuild_project" "build" {
  name          = "${var.name}-build"
  service_role  = aws_iam_role.build.arn
  build_timeout = 10

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec.yml"
  }

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    type         = "LINUX_CONTAINER"
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/standard:7.0"
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.build.name
    }
  }
}

############################
# CodeBuild: DB migrations, runs in the private subnets.
# The only principal that can read the master secret.
############################
resource "aws_iam_role" "migrate" {
  name               = "codebuild-webapp-migrate-role"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume.json
}

data "aws_iam_policy_document" "migrate" {
  source_policy_documents = [data.aws_iam_policy_document.codebuild_base.json]

  statement {
    sid       = "ReadDbSecrets"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.master_secret_arn, var.app_secret_arn]
  }

  # Required for CodeBuild VPC mode
  statement {
    sid = "VpcEni"
    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:DescribeDhcpOptions",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DeleteNetworkInterface",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeVpcs",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "VpcEniPermission"
    actions   = ["ec2:CreateNetworkInterfacePermission"]
    resources = ["arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${local.account_id}:network-interface/*"]
    condition {
      test     = "StringEquals"
      variable = "ec2:AuthorizedService"
      values   = ["codebuild.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "ec2:Subnet"
      values   = [for s in var.private_subnet_ids : "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${local.account_id}:subnet/${s}"]
    }
  }
}

resource "aws_iam_role_policy" "migrate" {
  name   = "codebuild-migrate"
  role   = aws_iam_role.migrate.id
  policy = data.aws_iam_policy_document.migrate.json
}

resource "aws_cloudwatch_log_group" "migrate" {
  name              = "/aws/codebuild/${var.name}-migrate"
  retention_in_days = 30
}

resource "aws_codebuild_project" "migrate" {
  name          = "${var.name}-migrate"
  service_role  = aws_iam_role.migrate.arn
  build_timeout = 10

  source {
    type = "CODEPIPELINE"
    # Buildspec lives here, not in the app repo, so a commit can't change
    # what runs with master credentials.
    buildspec = <<-EOT
      version: 0.2
      phases:
        install:
          runtime-versions:
            python: 3.12
          commands:
            - pip install --quiet pymysql==1.1.1 cryptography boto3
            - curl -fsSL https://truststore.pki.rds.amazonaws.com/${var.aws_region}/${var.aws_region}-bundle.pem -o /tmp/rds-ca.pem
        build:
          commands:
            - python db/migrate.py
    EOT
  }

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    type         = "LINUX_CONTAINER"
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/standard:7.0"

    environment_variable {
      name  = "RDS_CA_BUNDLE"
      value = "/tmp/rds-ca.pem"
    }
    environment_variable {
      name  = "DB_MASTER_SECRET_ARN"
      value = var.master_secret_arn
    }
    environment_variable {
      name  = "DB_APP_SECRET_ARN"
      value = var.app_secret_arn
    }
  }

  vpc_config {
    vpc_id             = var.vpc_id
    subnets            = var.private_subnet_ids
    security_group_ids = [var.codebuild_sg_id]
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.migrate.name
    }
  }

  depends_on = [aws_iam_role_policy.migrate]
}

############################
# CodeDeploy
############################
data "aws_iam_policy_document" "codedeploy_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codedeploy.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codedeploy" {
  name               = "codedeploy-webapp-role"
  assume_role_policy = data.aws_iam_policy_document.codedeploy_assume.json
}

resource "aws_iam_role_policy_attachment" "codedeploy" {
  role       = aws_iam_role.codedeploy.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSCodeDeployRole"
}

# ASGs built from launch templates need these on top of AWSCodeDeployRole
data "aws_iam_policy_document" "codedeploy_lt" {
  statement {
    actions   = ["iam:PassRole"]
    resources = [var.instance_role_arn]
  }
  statement {
    actions   = ["ec2:CreateTags", "ec2:RunInstances"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "codedeploy_lt" {
  name   = "launch-template-support"
  role   = aws_iam_role.codedeploy.id
  policy = data.aws_iam_policy_document.codedeploy_lt.json
}

resource "aws_codedeploy_app" "this" {
  name             = var.name
  compute_platform = "Server"
}

resource "aws_codedeploy_deployment_group" "this" {
  app_name               = aws_codedeploy_app.this.name
  deployment_group_name  = "${var.name}-dg"
  service_role_arn       = aws_iam_role.codedeploy.arn
  deployment_config_name = "CodeDeployDefault.OneAtATime"
  autoscaling_groups     = [var.asg_name]

  outdated_instances_strategy = "UPDATE"

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "IN_PLACE"
  }

  load_balancer_info {
    target_group_info {
      name = var.target_group_name
    }
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }

  depends_on = [aws_iam_role_policy_attachment.codedeploy, aws_iam_role_policy.codedeploy_lt]
}

############################
# CodePipeline (V2)
############################
data "aws_iam_policy_document" "pipeline_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "pipeline" {
  name               = "codepipeline-webapp-role"
  assume_role_policy = data.aws_iam_policy_document.pipeline_assume.json
}

data "aws_iam_policy_document" "pipeline" {
  statement {
    sid       = "Artifacts"
    actions   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:GetBucketVersioning", "s3:GetBucketLocation"]
    resources = [var.artifacts_bucket_arn, "${var.artifacts_bucket_arn}/*"]
  }

  dynamic "statement" {
    for_each = local.is_codecommit ? [1] : []
    content {
      sid = "CodeCommitSource"
      actions = [
        "codecommit:GetBranch",
        "codecommit:GetCommit",
        "codecommit:GetRepository",
        "codecommit:UploadArchive",
        "codecommit:GetUploadArchiveStatus",
        "codecommit:CancelUploadArchive",
      ]
      resources = [aws_codecommit_repository.this[0].arn]
    }
  }

  dynamic "statement" {
    for_each = local.is_codecommit ? [] : [1]
    content {
      sid       = "GitHubSource"
      actions   = ["codestar-connections:UseConnection", "codeconnections:UseConnection"]
      resources = [aws_codestarconnections_connection.github[0].arn]
    }
  }

  statement {
    sid       = "CodeBuild"
    actions   = ["codebuild:StartBuild", "codebuild:BatchGetBuilds"]
    resources = [aws_codebuild_project.build.arn, aws_codebuild_project.migrate.arn]
  }

  statement {
    sid = "CodeDeploy"
    actions = [
      "codedeploy:CreateDeployment",
      "codedeploy:GetDeployment",
      "codedeploy:GetDeploymentConfig",
      "codedeploy:GetApplication",
      "codedeploy:GetApplicationRevision",
      "codedeploy:RegisterApplicationRevision",
    ]
    resources = [
      aws_codedeploy_app.this.arn,
      aws_codedeploy_deployment_group.this.arn,
      "arn:${data.aws_partition.current.partition}:codedeploy:${var.aws_region}:${local.account_id}:deploymentconfig:*",
    ]
  }
}

resource "aws_iam_role_policy" "pipeline" {
  name   = "codepipeline-webapp"
  role   = aws_iam_role.pipeline.id
  policy = data.aws_iam_policy_document.pipeline.json
}

locals {
  source_action = local.is_codecommit ? {
    provider = "CodeCommit"
    configuration = tomap({
      RepositoryName       = var.name
      BranchName           = var.source_branch
      PollForSourceChanges = "false" # EventBridge rule below triggers instead
      OutputArtifactFormat = "CODE_ZIP"
    })
    } : {
    provider = "CodeStarSourceConnection"
    configuration = tomap({
      ConnectionArn        = one(aws_codestarconnections_connection.github[*].arn)
      FullRepositoryId     = var.github_repository
      BranchName           = var.source_branch
      OutputArtifactFormat = "CODE_ZIP"
    })
  }
}

resource "aws_codepipeline" "this" {
  name          = "${var.name}-pipeline"
  role_arn      = aws_iam_role.pipeline.arn
  pipeline_type = "V2"

  artifact_store {
    type     = "S3"
    location = var.artifacts_bucket
  }

  stage {
    name = "Source"
    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = local.source_action.provider
      version          = "1"
      output_artifacts = ["SourceOutput"]
      configuration    = local.source_action.configuration
    }
  }

  stage {
    name = "Build"
    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["SourceOutput"]
      output_artifacts = ["BuildOutput"]
      configuration = {
        ProjectName = aws_codebuild_project.build.name
      }
    }
  }

  stage {
    name = "Migrate"
    action {
      name            = "DbMigrate"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["SourceOutput"]
      configuration = {
        ProjectName = aws_codebuild_project.migrate.name
      }
    }
  }

  stage {
    name = "Deploy"
    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "CodeDeploy"
      version         = "1"
      input_artifacts = ["BuildOutput"]
      configuration = {
        ApplicationName     = aws_codedeploy_app.this.name
        DeploymentGroupName = aws_codedeploy_deployment_group.this.deployment_group_name
      }
    }
  }

  depends_on = [aws_iam_role_policy.pipeline, aws_codecommit_repository.this]
}

############################
# CodeCommit push -> pipeline trigger
############################
data "aws_iam_policy_document" "events_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "events" {
  count              = local.is_codecommit ? 1 : 0
  name               = "${var.name}-pipeline-trigger"
  assume_role_policy = data.aws_iam_policy_document.events_assume.json
}

resource "aws_iam_role_policy" "events" {
  count = local.is_codecommit ? 1 : 0
  name  = "start-pipeline"
  role  = aws_iam_role.events[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "codepipeline:StartPipelineExecution"
      Resource = aws_codepipeline.this.arn
    }]
  })
}

resource "aws_cloudwatch_event_rule" "push" {
  count       = local.is_codecommit ? 1 : 0
  name        = "${var.name}-codecommit-push"
  description = "Start pipeline on push to ${var.source_branch}"
  event_pattern = jsonencode({
    source        = ["aws.codecommit"]
    "detail-type" = ["CodeCommit Repository State Change"]
    resources     = [aws_codecommit_repository.this[0].arn]
    detail = {
      event         = ["referenceCreated", "referenceUpdated"]
      referenceType = ["branch"]
      referenceName = [var.source_branch]
    }
  })
}

resource "aws_cloudwatch_event_target" "push" {
  count    = local.is_codecommit ? 1 : 0
  rule     = aws_cloudwatch_event_rule.push[0].name
  arn      = aws_codepipeline.this.arn
  role_arn = aws_iam_role.events[0].arn
}

############################
# Outputs
############################
output "pipeline_name" { value = aws_codepipeline.this.name }

output "codecommit_clone_url_http" {
  value = one(aws_codecommit_repository.this[*].clone_url_http)
}

output "github_connection_arn" {
  value = one(aws_codestarconnections_connection.github[*].arn)
}
