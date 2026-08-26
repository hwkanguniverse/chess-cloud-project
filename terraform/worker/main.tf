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

variable "chesscom_user_agent" {
  description = <<-EOT
    Sent on every request to Chess.com's Published Data API. The API is free
    and unauthenticated, so this header is the only thing identifying us: they
    use it to make contact before blocking an IP. A missing or anonymous UA is
    the difference between an email and a ban, which is why it is configuration
    rather than an optional nicety. Keep it in step with the API root's copy.
  EOT
  type        = string
  default     = "chess-cloud-project/0.1 (learning project; wenkang.hoo@gmail.com)"
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

  eval_queue_url  = data.terraform_remote_state.queue.outputs.eval_queue_url
  eval_queue_arn  = data.terraform_remote_state.queue.outputs.eval_queue_arn
  eval_queue_name = element(split(":", local.eval_queue_arn), length(split(":", local.eval_queue_arn)) - 1)
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
  force_delete         = true      # images are rebuildable artifacts, not data - destroy must not need a manual empty-the-repo step

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
        Effect = "Allow"
        # Both log groups. This role is shared by the ingestion worker and the
        # evaluator, and it is the *execution* role - the one the ECS agent
        # uses to pull the image and open the log stream, before any container
        # code runs. Scoping it to one group meant the evaluator could not
        # start at all: the task was placed, failed to create its stream, and
        # was killed before the entrypoint executed. A task role misconfigured
        # this way fails inside the container and logs why; an execution role
        # fails outside it and only the service events say so.
        Action = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = [
          "${aws_cloudwatch_log_group.worker.arn}:*",
          "${aws_cloudwatch_log_group.evaluator.arn}:*",
        ]
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
        Effect = "Allow"
        # GetItem alongside UpdateItem: the worker reads the item before
        # fetching, because the stored ETag is the only record that a previous
        # fetch happened and the worker holds no state between messages. That
        # read is what makes a conditional request possible, so without this
        # permission every message fails - and fails *generically*, retrying
        # five times into the DLQ as though Chess.com were down.
        #
        # BatchWriteItem and Query arrived with per-game items: the worker
        # writes each game as its own item and Queries the month's prefix to
        # find stale ones left by a longer previous fetch. Both are distinct
        # IAM actions - BatchWriteItem is not covered by PutItem or
        # UpdateItem, and granting the wrong one fails exactly as described
        # above, which is how this was found.
        Action = [
          "dynamodb:GetItem",
          "dynamodb:UpdateItem",
          "dynamodb:BatchWriteItem",
          "dynamodb:Query",
        ]
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
  # 0.25 vCPU / 0.5 GB, the smallest Fargate size. Still right for real
  # ingestion: the work is one HTTP request and one write per message, so it is
  # I/O-bound, not CPU-bound. The largest month measured is 3.4MB on the wire
  # and 145KB stored, well inside 512MB. Revisit for Stockfish, which is the
  # first thing here that will actually want CPU.
  cpu                = 256
  memory             = 512
  execution_role_arn = aws_iam_role.execution.arn
  task_role_arn      = aws_iam_role.task.arn

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
        # Chess.com's API is unauthenticated, so this header is the only thing
        # identifying us to them. They use it to make contact before blocking
        # an IP, which is why it is configuration rather than a nicety.
        { name = "CHESSCOM_USER_AGENT", value = var.chesscom_user_agent },
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

  # NOT a tuning knob, and not a number to raise on intuition.
  #
  # Chess.com's rule is "serial access is unlimited; parallel requests may
  # return 429". That is phrased per *caller*, not per player - so it is not
  # established that splitting work by username would make concurrency safe.
  # Two workers on different players are still two of our requests overlapping
  # in time, which is the thing the rule appears to prohibit.
  #
  # So: one task is the only configuration known to comply. The safe
  # concurrency, if any, is unknown.
  #
  # Establishing the real limit is a prerequisite to raising this - not an
  # optimisation to attempt first. The cheapest way is to ask, using the
  # contact address already in our User-Agent (that is what it is for); the
  # developer community is the right channel. Measuring is weak evidence in
  # the wrong direction: absence of a 429 at concurrency 2 for a few minutes
  # does not prove it is safe sustained, and the failure mode is an IP ban
  # that breaks the product for every user and cannot be bought back the way
  # a bill can.
  #
  # If the limit turns out to be per-player, SQS FIFO with MessageGroupId =
  # username is *a* mechanism to enforce it - one in-flight message per group.
  # That is a tool for a constraint we have not confirmed, not the answer.
  # See PHASE-F.md.
  max_capacity = 1
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


# --- Evaluator --------------------------------------------------------------
#
# The second worker. Everything here mirrors the ingestion worker except the
# two things that differ, and those two are the whole point:
#
#   - it scales to eval_max_tasks, not 1, because it makes no upstream requests
#   - it runs on 1 vCPU / 2 GB, because Stockfish is CPU-bound where ingestion
#     waits on HTTP
#
# It shares the image, the cluster, the security group and the execution role.
# Only the task role differs, because the permissions differ.

variable "eval_max_tasks" {
  description = <<-EOT
    How many evaluators may run at once. Unlike the ingestion worker's
    max_capacity this IS a tuning knob: evaluation touches nothing outside the
    account, so the only cost of getting it wrong is money.

    Ten is chosen for latency, not throughput. Concurrency is free in total
    cost - Fargate bills per vCPU-second, so ten tasks for a tenth of the time
    is the same bill - but ten IDLE tasks are ~108 USD/month against a ~2 USD
    budget, which is why scale-to-zero matters more here than anywhere else.
  EOT
  type        = number
  default     = 10
}

variable "eval_depth" {
  description = <<-EOT
    Stockfish search depth. Chosen by measurement: benchmarked over 1,047 plies
    of real games, depth 8 finds 53% of depth-18's blunders and reports half
    the true average centipawn loss, and depth 12 reaches 65%. Chess.com's own
    Game Review runs 18-30 by membership tier.

    Cost is controlled by bounding the GAMES (last 100 per time control), not
    the depth - that is what makes full depth affordable.
  EOT
  type        = number
  default     = 18
}

resource "aws_cloudwatch_log_group" "evaluator" {
  name              = "/ecs/chess-cloud-evaluator"
  retention_in_days = 14
}

resource "aws_iam_role" "evaluator_task" {
  name = "chess-cloud-evaluator-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "evaluator_task" {
  name = "evaluator"
  role = aws_iam_role.evaluator_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = local.eval_queue_arn
      },
      {
        Effect = "Allow"
        # Query to select a player's games, UpdateItem to write evals onto them
        # one game at a time. No BatchWriteItem: a game is the unit of work, so
        # writing it alone is what keeps a crash from losing more than one.
        # No PutItem or DeleteItem - the evaluator adds fields to rows that
        # ingestion owns, and must never create or destroy them.
        Action   = ["dynamodb:Query", "dynamodb:UpdateItem"]
        Resource = local.table_arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.evaluator.arn}:*"
      },
    ]
  })
}

resource "aws_ecs_task_definition" "evaluator" {
  family                   = "chess-cloud-evaluator"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  # 1 vCPU / 2 GB, four times the ingestion worker. Stockfish is CPU-bound
  # where ingestion waits on HTTP, and the sizing is roughly cost-NEUTRAL:
  # four times faster at four times the rate. So this buys latency, not
  # throughput per dollar, which is the only reason to pick it.
  cpu                = 1024
  memory             = 2048
  execution_role_arn = aws_iam_role.execution.arn
  task_role_arn      = aws_iam_role.evaluator_task.arn

  container_definitions = jsonencode([
    {
      name      = "evaluator"
      image     = "${aws_ecr_repository.worker.repository_url}:${var.image_tag}"
      essential = true
      # Same image as the ingestion worker, different entrypoint. They share a
      # table, a row shape and an operational story; two images would be two
      # things to keep in step for one differing line.
      command = ["python", "-u", "evaluator.py"]
      environment = [
        { name = "EVAL_QUEUE_URL", value = local.eval_queue_url },
        { name = "TABLE_NAME", value = local.table_name },
        { name = "AWS_DEFAULT_REGION", value = var.region },
        { name = "EVAL_DEPTH", value = tostring(var.eval_depth) },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.evaluator.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "evaluator"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "evaluator" {
  name            = "evaluator"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.evaluator.arn
  desired_count   = 0

  capacity_provider_strategy {
    capacity_provider = var.use_spot ? "FARGATE_SPOT" : "FARGATE"
    weight            = 1
  }

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.worker.id]
    assign_public_ip = true
  }

  lifecycle {
    ignore_changes = [desired_count]
  }
}

resource "aws_appautoscaling_target" "evaluator" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.evaluator.name}"
  scalable_dimension = "ecs:service:DesiredCount"

  # Zero is as load-bearing here as on the ingestion worker, and costs more to
  # get wrong: ten idle tasks at this size are ~108 USD/month.
  min_capacity = 0
  max_capacity = var.eval_max_tasks
}

resource "aws_appautoscaling_policy" "evaluator_scale_out" {
  name               = "evaluator-queue-has-work"
  policy_type        = "StepScaling"
  service_namespace  = "ecs"
  resource_id        = aws_appautoscaling_target.evaluator.resource_id
  scalable_dimension = aws_appautoscaling_target.evaluator.scalable_dimension

  step_scaling_policy_configuration {
    adjustment_type         = "ExactCapacity"
    cooldown                = 60
    metric_aggregation_type = "Maximum"

    # One player per message, so queue depth is exactly the number of players
    # waiting. A few waiting gets a few workers; more than five goes straight
    # to the ceiling rather than climbing one step at a time.
    step_adjustment {
      metric_interval_lower_bound = 0
      metric_interval_upper_bound = 5
      scaling_adjustment          = 2
    }
    step_adjustment {
      metric_interval_lower_bound = 5
      scaling_adjustment          = var.eval_max_tasks
    }
  }
}

resource "aws_appautoscaling_policy" "evaluator_scale_in" {
  name               = "evaluator-queue-empty"
  policy_type        = "StepScaling"
  service_namespace  = "ecs"
  resource_id        = aws_appautoscaling_target.evaluator.resource_id
  scalable_dimension = aws_appautoscaling_target.evaluator.scalable_dimension

  step_scaling_policy_configuration {
    adjustment_type         = "ExactCapacity"
    cooldown                = 60
    metric_aggregation_type = "Maximum"

    step_adjustment {
      metric_interval_upper_bound = 0
      scaling_adjustment          = 0
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "eval_queue_has_work" {
  alarm_name          = "chess-cloud-eval-queue-has-work"
  alarm_description   = "Players waiting for evaluation - start evaluators"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = local.eval_queue_name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  alarm_actions       = [aws_appautoscaling_policy.evaluator_scale_out.arn]
  treat_missing_data  = "notBreaching"
}

# Visible messages ALONE are the wrong signal here, and this was found by
# watching it fail: a task was killed six minutes into a three-hour job.
#
# ApproximateNumberOfMessagesVisible drops to zero the instant a worker
# receives a message, so for the whole time the evaluator is working the queue
# reads empty. The ingestion worker gets away with the same alarm because its
# messages take about a second; this one holds a message for hours.
#
# Summing Visible + NotVisible counts work in flight as work, so the service
# only scales in when nothing is queued AND nothing is being processed.
resource "aws_cloudwatch_metric_alarm" "eval_queue_empty" {
  alarm_name        = "chess-cloud-eval-queue-empty"
  alarm_description = "Evaluation queue empty and nothing in flight - scale to zero"

  metric_query {
    id          = "total"
    expression  = "visible + inflight"
    label       = "Messages queued or in flight"
    return_data = true
  }

  metric_query {
    id = "visible"
    metric {
      namespace   = "AWS/SQS"
      metric_name = "ApproximateNumberOfMessagesVisible"
      dimensions  = { QueueName = local.eval_queue_name }
      period      = 60
      stat        = "Maximum"
    }
  }

  metric_query {
    id = "inflight"
    metric {
      namespace   = "AWS/SQS"
      metric_name = "ApproximateNumberOfMessagesNotVisible"
      dimensions  = { QueueName = local.eval_queue_name }
      period      = 60
      stat        = "Maximum"
    }
  }

  evaluation_periods  = var.scale_in_minutes
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  alarm_actions       = [aws_appautoscaling_policy.evaluator_scale_in.arn]
  treat_missing_data  = "breaching"
}
