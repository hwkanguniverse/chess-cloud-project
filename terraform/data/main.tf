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

  attribute {
    name = "classKey"
    type = "S"
  }

  # No GSI on gameId, deliberately. Both lookup patterns are served by the
  # primary key alone; a GSI would be eventually consistent, so a status poll
  # immediately after submit could 404 on a game that exists.
  #
  # by-class is a different case: "a player's newest 100 games in one time
  # control", which evaluation selection (analyse.py) and progress
  # (player.py) both need. On the primary key that meant walking the player's
  # games newest-first until the *rarest* class reached 100 - found by X-Ray
  # on 29 Sep: 22 of 28 pages (~22 MB) for a player with 778 blitz games, and
  # the whole history for anyone with fewer than 100 in any class. Here it is
  # one Query with Limit 100 per class, whatever the history size.
  #
  # KEYS_ONLY plus evalDepth: ~100 bytes a game instead of the ~2.6 KB item
  # (PGN and evals), because a Query pays for what it reads, not what it
  # returns. Sparse by construction - only game items carry classKey.
  #
  # Eventually consistent is acceptable here, unlike for gameId: a game
  # evaluated a second ago may read as outstanding, so progress lags by a
  # second and at worst analyse re-queues it, which the evaluator's evalDepth
  # guard already absorbs.
  global_secondary_index {
    name = "by-class"
    key_schema {
      attribute_name = "classKey"
      key_type       = "HASH"
    }
    key_schema {
      attribute_name = "SK"
      key_type       = "RANGE"
    }
    projection_type    = "INCLUDE"
    non_key_attributes = ["evalDepth"]
  }

  # Short-lived control items carry an expiresAt and are swept by DynamoDB:
  # rate-limit buckets, per-player analyse claims and the daily game cap. It
  # was added for in-flight OAuth link attempts, removed with account linking
  # on 30 Sep 2026. Deletion is free and asynchronous - within ~48h of expiry,
  # not instantly - so the handlers must still treat an expired item as absent
  # rather than trusting the sweep to have run.
  ttl {
    attribute_name = "expiresAt"
    enabled        = true
  }

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
