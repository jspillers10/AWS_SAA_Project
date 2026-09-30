variable "name" { type = string }
variable "aws_region" { type = string }
variable "alert_email" { type = string }
variable "alb_arn_suffix" { type = string }
variable "target_group_arn_suffix" { type = string }
variable "asg_name" { type = string }
variable "db_instance_id" { type = string }
variable "rds_connection_threshold" { type = number }

############################
# SNS
############################
resource "aws_sns_topic" "alerts" {
  name         = "webapp-alerts"
  display_name = "WebApp Production Alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

############################
# Alarms (the 5 from the console build)
############################
locals {
  alarms = {
    alb-unhealthy-targets = {
      description = "Any ALB target unhealthy"
      namespace   = "AWS/ApplicationELB"
      metric      = "UnHealthyHostCount"
      statistic   = "Maximum"
      periods     = 2
      threshold   = 1
      comparison  = "GreaterThanOrEqualToThreshold"
      missing     = "missing"
      dimensions  = { LoadBalancer = var.alb_arn_suffix, TargetGroup = var.target_group_arn_suffix }
    }
    asg-high-cpu = {
      description = "ASG average CPU above 80% for 10 minutes"
      namespace   = "AWS/EC2"
      metric      = "CPUUtilization"
      statistic   = "Average"
      periods     = 2
      threshold   = 80
      comparison  = "GreaterThanThreshold"
      missing     = "missing"
      dimensions  = { AutoScalingGroupName = var.asg_name }
    }
    rds-high-connections = {
      description = "RDS connection count approaching max_connections"
      namespace   = "AWS/RDS"
      metric      = "DatabaseConnections"
      statistic   = "Average"
      periods     = 2
      threshold   = var.rds_connection_threshold
      comparison  = "GreaterThanThreshold"
      missing     = "missing"
      dimensions  = { DBInstanceIdentifier = var.db_instance_id }
    }
    alb-5xx-errors = {
      description = "Target 5xx responses above 10 in 5 minutes"
      namespace   = "AWS/ApplicationELB"
      metric      = "HTTPCode_Target_5XX_Count"
      statistic   = "Sum"
      periods     = 1
      threshold   = 10
      comparison  = "GreaterThanThreshold"
      missing     = "notBreaching"
      dimensions  = { LoadBalancer = var.alb_arn_suffix }
    }
    rds-low-storage = {
      description = "RDS free storage below 2 GiB"
      namespace   = "AWS/RDS"
      metric      = "FreeStorageSpace"
      statistic   = "Average"
      periods     = 1
      threshold   = 2147483648
      comparison  = "LessThanThreshold"
      missing     = "missing"
      dimensions  = { DBInstanceIdentifier = var.db_instance_id }
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each = local.alarms

  alarm_name          = "${var.name}-${each.key}"
  alarm_description   = each.value.description
  namespace           = each.value.namespace
  metric_name         = each.value.metric
  statistic           = each.value.statistic
  period              = 300
  evaluation_periods  = each.value.periods
  threshold           = each.value.threshold
  comparison_operator = each.value.comparison
  treat_missing_data  = each.value.missing
  dimensions          = each.value.dimensions

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

############################
# Dashboard
############################
resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = var.name

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "ALB"
          region = var.aws_region
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix],
            [".", "HTTPCode_Target_2XX_Count", ".", "."],
            [".", "HTTPCode_Target_5XX_Count", ".", "."],
            [".", "TargetResponseTime", ".", ".", { stat = "Average", yAxis = "right" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "EC2 / ASG"
          region = var.aws_region
          stat   = "Average"
          period = 60
          metrics = [
            ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", var.asg_name],
            [".", "NetworkIn", ".", ".", { stat = "Sum", yAxis = "right" }],
            [".", "NetworkOut", ".", ".", { stat = "Sum", yAxis = "right" }],
            ["AWS/AutoScaling", "GroupInServiceInstances", "AutoScalingGroupName", var.asg_name],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title  = "RDS"
          region = var.aws_region
          stat   = "Average"
          period = 60
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", var.db_instance_id],
            [".", "DatabaseConnections", ".", "."],
            [".", "ReadIOPS", ".", "."],
            [".", "WriteIOPS", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title  = "RDS free storage (bytes)"
          region = var.aws_region
          stat   = "Minimum"
          period = 300
          metrics = [
            ["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", var.db_instance_id],
          ]
        }
      },
      {
        type = "alarm", x = 0, y = 12, width = 24, height = 3
        properties = {
          title  = "Alarms"
          alarms = [for a in aws_cloudwatch_metric_alarm.this : a.arn]
        }
      },
    ]
  })
}

output "sns_topic_arn" { value = aws_sns_topic.alerts.arn }
output "dashboard_url" {
  value = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.this.dashboard_name}"
}
