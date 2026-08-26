# Queue layer: the buffer between the submit Lambda and the analysis worker.
#
# The queue does three jobs, and decoupling is only the obvious one:
#
#   1. Decouples submit (~100ms) from analysis (30-90s/game). API Gateway caps
#      a request at 29s regardless of Lambda's own timeout, so queueing is what
#      the ceiling forces, not a preference.
#   2. Load-levels: a 500-game upload is accepted in a second and drained at
#      whatever rate the worker manages.
#   3. Supplies the autoscaling signal. Queue depth is what lets the worker
#      scale to zero, which is the difference between ~$0 and ~$44/month.

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
    key          = "queue/terraform.tfstate"
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

variable "queue_name" {
  description = "Name of the analysis work queue."
  type        = string
  default     = "chess-cloud-analysis"
}

variable "visibility_timeout_seconds" {
  description = <<-EOT
    How long a message stays hidden after a worker receives it. Sized for real
    Stockfish analysis (30-90s/game), not Phase 1's 10s fake worker, so the
    value never needs revisiting when the engine lands.

    Too short and a second worker starts a game the first is still analysing.
    Too long and a crashed worker's message waits that long before retry.
  EOT
  type        = number
  default     = 180
}

variable "max_receive_count" {
  description = <<-EOT
    Deliveries before a message is moved to the DLQ. Three rides out a
    transient crash or a Spot reclaim while quarantining a genuinely poison
    game quickly - each retry costs a full analysis attempt in Fargate time.
  EOT
  type        = number
  default     = 3
}

# Dead letter queue. Created alongside the main queue rather than retrofitted:
# adding one after a poison message already exists means draining a stuck queue
# by hand. Retention is the 14-day maximum because these are the messages worth
# inspecting - a game lands here only after failing every retry.
resource "aws_sqs_queue" "analysis_dlq" {
  name                      = "${var.queue_name}-dlq"
  message_retention_seconds = 1209600 # 14 days, the maximum
}

resource "aws_sqs_queue" "analysis" {
  name = var.queue_name

  visibility_timeout_seconds = var.visibility_timeout_seconds

  # Long polling. The default of 0 is short polling, where the worker asks
  # "anything?", gets an instant "no", and immediately asks again - burning CPU
  # and API calls while idle. At 20s SQS holds the connection open until a
  # message arrives or the wait expires.
  receive_wait_time_seconds = 20

  message_retention_seconds = 345600 # 4 days

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.analysis_dlq.arn
    maxReceiveCount     = var.max_receive_count
  })
}

# Restricts which queues may use this one as a redrive target - only the main
# analysis queue can. Note this governs redrive only: a direct SendMessage with
# sufficient IAM permission still succeeds (verified). Keeping arrivals-by-
# redrive the only real path is therefore an IAM job, handled when the Lambda
# and worker roles are scoped.
resource "aws_sqs_queue_redrive_allow_policy" "analysis_dlq" {
  queue_url = aws_sqs_queue.analysis_dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.analysis.arn]
  })
}

# --- Evaluation queue -------------------------------------------------------

# A second queue, because the two workers have opposite constraints. Ingestion
# is pinned to one task to protect Chess.com's API - the failure mode there is
# an IP ban, which money cannot undo. Evaluation reads PGNs already in the
# table and runs a local binary, so it makes no upstream requests and scales
# freely. Sharing one queue would force the stricter limit on both.

resource "aws_sqs_queue" "evaluation_dlq" {
  name                      = "${var.queue_name}-eval-dlq"
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue" "evaluation" {
  name = "${var.queue_name}-eval"

  # One message is one player: up to 400 games (100 per time control) at ~56s
  # each at depth 18, so 6.2 hours worst case against the 12h SQS maximum.
  #
  # The consequence worth knowing: a player is analysed by ONE worker, so
  # adding workers speeds up *concurrent players*, not a single large one.
  # Splitting a player across workers would mean one message per game and a
  # way to know when the set is done - real work, not yet justified while the
  # cap keeps the worst case to hours rather than days.
  visibility_timeout_seconds = 25200 # 7h, worst case plus headroom

  receive_wait_time_seconds = 20
  message_retention_seconds = 345600

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.evaluation_dlq.arn
    # Two, not three. Each retry here is up to six hours of Fargate time
    # rather than a few seconds of HTTP, so a poison message is far more
    # expensive to keep retrying than it is to quarantine.
    maxReceiveCount = 2
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "evaluation_dlq" {
  queue_url = aws_sqs_queue.evaluation_dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.evaluation.arn]
  })
}

output "eval_queue_url" {
  value = aws_sqs_queue.evaluation.url
}

output "eval_queue_arn" {
  description = "For scoping the analyse Lambda's send and the evaluator's receive/delete."
  value       = aws_sqs_queue.evaluation.arn
}

output "eval_dlq_url" {
  value = aws_sqs_queue.evaluation_dlq.url
}

output "eval_dlq_arn" {
  value = aws_sqs_queue.evaluation_dlq.arn
}

output "queue_url" {
  value = aws_sqs_queue.analysis.url
}

output "queue_arn" {
  description = "For scoping the submit Lambda's send and the worker's receive/delete permissions."
  value       = aws_sqs_queue.analysis.arn
}

output "dlq_url" {
  value = aws_sqs_queue.analysis_dlq.url
}

output "dlq_arn" {
  value = aws_sqs_queue.analysis_dlq.arn
}
