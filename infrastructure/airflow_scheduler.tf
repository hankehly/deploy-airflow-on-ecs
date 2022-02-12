# Send scheduler logs to this Cloud Watch log group
resource "aws_cloudwatch_log_group" "airflow_scheduler" {
  name_prefix       = "/deploy-airflow-on-ecs-fargate/airflow-scheduler/"
  retention_in_days = 1
}

# Send scheduler logs to this Cloud Watch log group
resource "aws_cloudwatch_log_group" "airflow_scheduler_cloudwatch_agent" {
  name_prefix       = "/deploy-airflow-on-ecs-fargate/airflow-scheduler-cloudwatch-agent/"
  retention_in_days = 1
}

# https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-Agent-Configuration-File-Details.html
resource "aws_ssm_parameter" "airflow_ecs_cloudwatch_agent_config" {
  name        = "airflow-ecs-cloudwatch-agent-config"
  type        = "String"
  description = "CloudWatch agent configuration file for airflow ECS cluster"
  value = jsonencode(
    {
      agent = {
        region = var.aws_region,
        debug  = false
      }
      metrics = {
        namespace = local.airflow_cloud_watch_metrics_namespace
        metrics_collected = {
          # These are the default values
          statsd = {
            service_address              = ":8125"
            metrics_collection_interval  = 10
            metrics_aggregation_interval = 60
          }
        }
      }
    }
  )
}

# Scheduler service task definition
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_task_definition
resource "aws_ecs_task_definition" "airflow_scheduler" {
  family             = "airflow-scheduler"
  cpu                = 1024
  memory             = 2048
  execution_role_arn = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn      = aws_iam_role.airflow_task.arn
  network_mode       = "awsvpc"
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  requires_compatibilities = ["FARGATE"]
  container_definitions = jsonencode([
    {
      name   = "scheduler"
      image  = join(":", [aws_ecr_repository.airflow.repository_url, "latest"])
      cpu    = 1024
      memory = 2048
      healthcheck = {
        command = [
          "CMD-SHELL",
          "airflow jobs check --job-type SchedulerJob --hostname \"$${HOSTNAME}\""
        ]
        interval = 35
        timeout  = 30
        retries  = 5
      }
      essential = true
      command   = ["scheduler"]
      # Start the init process inside the container to remove any zombie SSM agent child processes found
      # https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ecs-exec.html#ecs-exec-task-definition
      linuxParameters = {
        initProcessEnabled = true
      }
      environment = local.airflow_task_common_environment
      user        = "50000:0"
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.airflow_scheduler.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "airflow-scheduler"
        }
      }
    },
    {
      name      = "cloudwatch-agent"
      essential = true
      image     = "public.ecr.aws/cloudwatch-agent/cloudwatch-agent:latest"
      secrets = [
        {
          name      = "CW_CONFIG_CONTENT",
          valueFrom = aws_ssm_parameter.airflow_ecs_cloudwatch_agent_config.name
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.airflow_scheduler_cloudwatch_agent.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "airflow-scheduler-cloudwatch-agent"
        }
      }
  }])
}

# Scheduler service security group (no incoming connections)
resource "aws_security_group" "airflow_scheduler_service" {
  name_prefix = "airflow-scheduler-"
  description = "Deny all incoming traffic"
  vpc_id      = aws_vpc.main.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Airflow ECS scheduler service
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_service
resource "aws_ecs_service" "airflow_scheduler" {
  name = "airflow-scheduler"
  # If a revision is not specified, the latest ACTIVE revision is used.
  task_definition = aws_ecs_task_definition.airflow_scheduler.family
  cluster         = aws_ecs_cluster.airflow.arn
  # If using awsvpc network mode, do not specify this role.
  # iam_role =
  deployment_controller {
    type = "ECS"
  }
  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100
  desired_count                      = 1
  lifecycle {
    ignore_changes = [desired_count]
  }
  enable_execute_command = true
  launch_type            = "FARGATE"
  network_configuration {
    subnets = [aws_subnet.public_a.id, aws_subnet.public_b.id]
    # For tasks on Fargate, in order for the task to pull the container image it must either
    # 1. use a public subnet and be assigned a public IP address
    # 2. use a private subnet that has a route to the internet or a NAT gateway
    assign_public_ip = true
    security_groups  = [aws_security_group.airflow_scheduler_service.id]
  }
  platform_version    = "1.4.0"
  scheduling_strategy = "REPLICA"
  # This can be used to update tasks to use a newer container image with same
  # image/tag combination (e.g., myimage:latest)
  force_new_deployment = var.force_new_ecs_service_deployment
}

# For this example, we want to save money by scaling to zero at night when we don't need to access the service.
# Target registration:
#  https://docs.aws.amazon.com/autoscaling/application/userguide/services-that-can-integrate-ecs.html#integrate-register-ecs
# Example scaling configurations:
#  https://docs.aws.amazon.com/autoscaling/application/userguide/examples-scheduled-actions.html
# ECS scheduled scaling example:
#  https://aws.amazon.com/blogs/containers/optimizing-amazon-elastic-container-service-for-cost-using-scheduled-scaling/
resource "aws_appautoscaling_target" "airflow_scheduler" {
  max_capacity       = 1
  min_capacity       = 0
  resource_id        = "service/${aws_ecs_cluster.airflow.name}/${aws_ecs_service.airflow_scheduler.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

# Scale to zero at night (21:00 Japan Standard Time)
resource "aws_appautoscaling_scheduled_action" "airflow_scheduler_scheduled_scale_in" {
  name               = "ecs"
  service_namespace  = aws_appautoscaling_target.airflow_scheduler.service_namespace
  resource_id        = aws_appautoscaling_target.airflow_scheduler.resource_id
  scalable_dimension = aws_appautoscaling_target.airflow_scheduler.scalable_dimension
  # Gotcha: Cron expressions have SIX required fields
  # https://docs.aws.amazon.com/AmazonCloudWatch/latest/events/ScheduledEvents.html#CronExpressions
  schedule = "cron(0 12 * * ? *)"
  scalable_target_action {
    min_capacity = 0
    max_capacity = 0
  }
}

# Scale to one during the day (10:00 Japan Standard Time)
resource "aws_appautoscaling_scheduled_action" "airflow_scheduler_scheduled_scale_out" {
  name               = "ecs"
  service_namespace  = aws_appautoscaling_target.airflow_scheduler.service_namespace
  resource_id        = aws_appautoscaling_target.airflow_scheduler.resource_id
  scalable_dimension = aws_appautoscaling_target.airflow_scheduler.scalable_dimension
  # Gotcha: Cron expressions have SIX required fields
  # https://docs.aws.amazon.com/AmazonCloudWatch/latest/events/ScheduledEvents.html#CronExpressions
  schedule = "cron(0 3 * * ? *)"
  scalable_target_action {
    min_capacity = 1
    max_capacity = 1
  }
  depends_on = [
    # Prevent a `ConcurrentUpdateException` by forcing sequential changes to autoscaling policies
    aws_appautoscaling_scheduled_action.airflow_scheduler_scheduled_scale_in
  ]
}
