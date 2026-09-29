# Guardrails: cost protection that must exist before any infrastructure is built.
#
# The roadmap's rule is a $5/month budget alert set BEFORE launching anything,
# because the expensive mistakes here (NAT Gateway ~$32/mo, idle Fargate ~$44/mo)
# are all things that quietly bill by the hour.

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
    key          = "guardrails/terraform.tfstate"
    region       = "ap-southeast-1"
    encrypt      = true
    use_lockfile = true # native S3 locking, TF 1.10+ (no DynamoDB lock table)
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

# AWS Budgets is a global service backed by us-east-1, regardless of where the
# infrastructure being billed actually runs.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

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

variable "monthly_budget_usd" {
  description = "Monthly spend ceiling in USD. The roadmap's guardrail figure."
  type        = string
  default     = "5"
}

variable "alert_email" {
  description = "Where budget alerts are delivered."
  type        = string
  default     = "wenkang.hoo@gmail.com"
}

resource "aws_budgets_budget" "monthly" {
  provider = aws.us_east_1

  name         = "chess-cloud-monthly"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_usd
  limit_unit   = "USD"

  # MONTHLY, not ANNUALLY. An annual $5 ceiling is exhausted by one ordinary
  # month, after which the budget sits permanently over and every alert it
  # sends becomes noise.
  time_unit = "MONTHLY"

  # Warns while there is still time to act: projects the current run rate to
  # month end and fires if that projection exceeds 80% of the limit.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }

  # Backstop: confirms the money is actually spent. On a new account with no
  # billing history the forecast can be unreliable, so both are kept.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }
}

# --- Operational alerts -----------------------------------------------------

# Where "something is wrong" alarms go, as opposed to the scaling alarms,
# which exist to move task counts and notify nobody. Lives here rather than
# beside any one alarm because it is shared: the queue root alarms on the DLQs,
# the worker root on game duration, and both read this ARN from remote state.
#
# The email subscription is created pending. AWS sends a confirmation link,
# and until it is clicked every notification is silently dropped - the alarm
# goes to ALARM and nothing arrives. The drift check asserts it is confirmed.
resource "aws_sns_topic" "alerts" {
  name = "chess-cloud-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

output "budget_name" {
  value = aws_budgets_budget.monthly.name
}

output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}
