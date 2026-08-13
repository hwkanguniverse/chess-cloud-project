# Data layer: the single DynamoDB table behind the whole pipeline.
#
# The submit Lambda writes PENDING items here, the status Lambda reads them,
# and the worker writes results back. One table, two access patterns, no index.

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
    key          = "data/terraform.tfstate"
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

variable "table_name" {
  description = "Name of the games table."
  type        = string
  default     = "chess-cloud-games"
}

# Key design (settled before the table existed - changing it later means
# migrating data, unlike most settings here):
#
#   PK = USER#<userId>
#   SK = GAME#<timestamp>#<gameId>
#
# Pattern 1, get one game: the API hands clients a composite id
# ("hikaru-1723526400-abc123") which the Lambda splits to rebuild both keys,
# then does a single GetItem. Parsing is rsplit("-", 2), not split - usernames
# may contain hyphens, so only the last two fields are safe to take, and
# gameIds must be generated hyphen-free (uuid4().hex).
# A bare gameId could not work - DynamoDB computes
# an item's location from the partition key rather than searching for it, and
# a gameId sits mid-string inside the sort key where prefix matching cannot
# reach it. Finding it would mean scanning the whole table on every poll.
#
# Pattern 2, list a user's games newest first: one Query on PK. Items sharing
# a partition key are stored together sorted by sort key, and the timestamp
# leads that key, so chronological order is free - no sorting in application
# code. Ordering by gameId first would make this a full fetch-and-sort.
resource "aws_dynamodb_table" "games" {
  name         = var.table_name
  billing_mode = "PAY_PER_REQUEST" # bursty traffic; idle costs nothing

  hash_key  = "PK"
  range_key = "SK"

  # Only key attributes are declared. DynamoDB is schemaless beyond its keys,
  # so status, pgn and eval data need no definition here.
  attribute {
    name = "PK"
    type = "S"
  }

  attribute {
    name = "SK"
    type = "S"
  }

  # No global secondary index, deliberately. Both access patterns are served by
  # the primary key alone; a GSI on gameId would be eventually consistent, so a
  # status poll immediately after submit could 404 on a game that exists.

  point_in_time_recovery {
    enabled = true
  }

  # This table is the only record that a game was ever submitted.
  lifecycle {
    prevent_destroy = true
  }
}

output "table_name" {
  value = aws_dynamodb_table.games.name
}

output "table_arn" {
  description = "For scoping Lambda and worker IAM policies to this table."
  value       = aws_dynamodb_table.games.arn
}
