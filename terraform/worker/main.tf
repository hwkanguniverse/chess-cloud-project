# Worker layer: ECR + ECS Fargate consuming the analysis queue.
#
# The one piece of this stack that is not a Lambda, for reasons that only
# fully arrive in Phase 3: Stockfish is a heavy native binary, CPU-bound for
# 30-90s per game, batches can outrun Lambda's 15-minute ceiling, and a warm
# engine process between games is worth keeping. Phase 1 runs the fake worker
# in the same shape so the plumbing is proven before the engine exists.
#
# Cost posture, per the roadmap:
#   - No NAT Gateway (~$32/mo): the task runs in the default VPC's public
#     subnets with a public IP. Nothing routes TO a queue consumer - it polls
#     out, nothing reaches in - so the security group allows zero inbound.
#   - Scale to zero: min 0 tasks, driven by queue depth. The difference
#     between ~$0 and ~$44/month, and the main cost lever in the design.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    bucket       = "chess-cloud-tfstate-961868442307"
    key          = "worker/terraform.tfstate"
    region       = "ap-southeast-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "chess-cloud"
      ManagedBy = "terraform"
    }
  }
}

variable "region" {
  description = "AWS region for project infrastructure."
  type        = string
  default     = "ap-southeast-1"
}

variable "image_tag" {
  description = "Tag of the worker image to deploy from ECR."
  type        = string
  default     = "latest"
}

variable "scale_in_minutes" {
  description = <<-EOT
    How long the queue must sit empty before the worker scales to zero.
    The trade-off: scaling in eagerly saves idle time (~$0.012/hr for this
    task size) but pays a 30-60s cold start plus Fargate's one-minute billing
    minimum on every restart, so trickled-in single games repeatedly pay
    startup. Lingering does the opposite. Decided at 5: covers a user
    submitting games one at a time while thinking, for ~$0.001 per linger.
  EOT
  type        = number
  default     = 5
}

variable "use_spot" {
  description = <<-EOT
    Run the worker on FARGATE_SPOT (~70% cheaper, can be reclaimed with a
    2-minute warning) instead of on-demand FARGATE. A reclaim mid-message is
    safe: the message reappears after the visibility timeout - the same
    at-least-once path a crash exercises, and one reason max receives is 3.
  EOT
  type        = bool
  default     = true
}

data "terraform_remote_state" "data" {
  backend = "s3"
  config = {
    bucket = "chess-cloud-tfstate-961868442307"
    key    = "data/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

data "terraform_remote_state" "queue" {
  backend = "s3"
  config = {
    bucket = "chess-cloud-tfstate-961868442307"
    key    = "queue/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

locals {
  table_name = data.terraform_remote_state.data.outputs.table_name
  table_arn  = data.terraform_remote_state.data.outputs.table_arn
  queue_url  = data.terraform_remote_state.queue.outputs.queue_url
  queue_arn  = data.terraform_remote_state.queue.outputs.queue_arn
  queue_name = element(split(":", local.queue_arn), length(split(":", local.queue_arn)) - 1)
}

# Default VPC networking: public subnets, no NAT, no ALB.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# No ingress blocks at all: a queue consumer accepts no connections. Egress
# only, for SQS/DynamoDB/ECR/CloudWatch over HTTPS.
resource "aws_security_group" "worker" {
  name        = "chess-cloud-worker"
  description = "Analysis worker - egress only, nothing routes in"
  vpc_id      = data.aws_vpc.default.id

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- ECR -------------------------------------------------------------------

resource "aws_ecr_repository" "worker" {
  name                 = "chess-cloud-worker"
  image_tag_mutability = "MUTABLE" # "latest" is re-pushed each build

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Storage is $0.10/GB/month; without a lifecycle policy every pushed image
# accumulates forever.
resource "aws_ecr_lifecycle_policy" "worker" {
  repository = aws_ecr_repository.worker.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep the last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

# --- Logs ------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/ecs/chess-cloud-worker"
  retention_in_days = 14
}

# --- IAM: the two commonly conflated roles ---------------------------------
# Execution role: used by AWS *before the code runs* - pull the image, create
# the log stream. Task role: what the code itself gets - SQS receive/delete
# and the table write. Receive/delete stays off the Lambda roles and DLQ
# permissions stay off this one, which keeps redrive the only real path into
# the DLQ.

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "chess-cloud-worker-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy" "execution" {
  name = "execution"
  role = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # GetAuthorizationToken is account-wide by design; it only supports "*".
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
        Resource = aws_ecr_repository.worker.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.worker.arn}:*"
      },
    ]
  })
}

resource "aws_iam_role" "task" {
  name               = "chess-cloud-worker-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy" "task" {
  name = "task"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility"]
        Resource = local.queue_arn
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:UpdateItem"]
        Resource = local.table_arn
      },
    ]
  })
}

# --- ECS -------------------------------------------------------------------

resource "aws_ecs_cluster" "main" {
  name = "chess-cloud"
  # Container Insights stays off - it bills per metric and the alarms this
  # project needs are on the queue, not the container.
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
}

resource "aws_ecs_task_definition" "worker" {
  family                   = "chess-cloud-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256 # 0.25 vCPU, the smallest Fargate size -
  memory                   = 512 # plenty for a sleep loop; revisit for Stockfish
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "worker"
      image     = "${aws_ecr_repository.worker.repository_url}:${var.image_tag}"
      essential = true
      environment = [
        { name = "QUEUE_URL", value = local.queue_url },
        { name = "TABLE_NAME", value = local.table_name },
        # boto3 discovers credentials from the task role automatically, but
        # not the region - ECS does not inject one.
        { name = "AWS_DEFAULT_REGION", value = var.region },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.worker.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "worker"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "worker" {
  name            = "worker"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = 0 # autoscaling owns this from here on

  capacity_provider_strategy {
    capacity_provider = var.use_spot ? "FARGATE_SPOT" : "FARGATE"
    weight            = 1
  }

  network_configuration {
    subnets         = data.aws_subnets.default.ids
    security_groups = [aws_security_group.worker.id]
    # Public IP is what replaces the NAT Gateway: without one of the two the
    # task cannot reach SQS/ECR and dies pulling its image.
    assign_public_ip = true
  }

  lifecycle {
    # Autoscaling changes desired_count at runtime; without this, every
    # apply would fight it back to 0 and kill a working task mid-drain.
    ignore_changes = [desired_count]
  }
}

# --- Autoscaling: the scale-to-zero machinery ------------------------------
# Target tracking cannot start from zero (zero tasks make every per-task
# ratio undefined), so this is step scaling on raw queue depth: any visible
# message -> 1 task; empty for scale_in_minutes -> 0 tasks.

resource "aws_appautoscaling_target" "worker" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.worker.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = 0 # the load-bearing number in the whole file
  max_capacity       = 1 # one task drains any Phase 1 backlog; parallelism is a Phase 4 tuning knob
}

resource "aws_appautoscaling_policy" "scale_out" {
  name               = "queue-has-work"
  service_namespace  = "ecs"
  resource_id        = aws_appautoscaling_target.worker.resource_id
  scalable_dimension = aws_appautoscaling_target.worker.scalable_dimension
  policy_type        = "StepScaling"

  step_scaling_policy_configuration {
    adjustment_type = "ExactCapacity"
    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment          = 1
    }
  }
}

resource "aws_appautoscaling_policy" "scale_in" {
  name               = "queue-empty"
  service_namespace  = "ecs"
  resource_id        = aws_appautoscaling_target.worker.resource_id
  scalable_dimension = aws_appautoscaling_target.worker.scalable_dimension
  policy_type        = "StepScaling"

  step_scaling_policy_configuration {
    adjustment_type = "ExactCapacity"
    step_adjustment {
      metric_interval_upper_bound = 0
      scaling_adjustment          = 0
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "queue_has_work" {
  alarm_name          = "chess-cloud-queue-has-work"
  alarm_description   = "Messages waiting - start the worker"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = local.queue_name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  alarm_actions       = [aws_appautoscaling_policy.scale_out.arn]
}

# Watches Visible only: a message being processed is *not* visible, so this
# can fire while the last game is still in flight. That is accepted - ECS
# sends SIGTERM, the fake worker finishes inside the 30s grace window, and
# even a hard kill just returns the message via the visibility timeout,
# where it re-triggers scale-out. The depth counter is approximate and lags,
# which cooldown-by-evaluation-periods absorbs - fine for scaling, though it
# was not fine for the drift check (see CLAUDE.md).
resource "aws_cloudwatch_metric_alarm" "queue_empty" {
  alarm_name          = "chess-cloud-queue-empty"
  alarm_description   = "Queue empty long enough - scale the worker to zero"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = local.queue_name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = var.scale_in_minutes
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  alarm_actions       = [aws_appautoscaling_policy.scale_in.arn]
}

output "ecr_repository_url" {
  description = "Push the worker image here."
  value       = aws_ecr_repository.worker.repository_url
}

output "cluster_name" {
  value = aws_ecs_cluster.main.name
}
