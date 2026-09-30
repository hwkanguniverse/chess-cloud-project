# Front door: an API Gateway HTTP API in front of thin Lambdas.
#
#   POST /games                                  -> submit: resolve the player's
#                                                   archives, claim and queue one
#                                                   message per month, 202
#   GET  /player/{platform}/{username}           -> player: every month for a
#                                                   player plus cumulative totals
#   GET  /analysis/{platform}/{username}/{month} -> status: one month, with games
#
# No function does real work. Fetching and counting a month happens on the
# worker, and API Gateway caps every request at 29s regardless of Lambda's own
# timeout - the queue is what that ceiling forces.
#
# Submit is the one that is no longer trivially fast: it makes an outbound call
# to Chess.com to resolve the archive list, then claims up to ~150 months. See
# its timeout below.
#
# HTTP API, not REST API: same job at ~$1/M requests instead of ~$3.50/M. The
# REST-only extras (API keys, usage plans, response caching) have no consumer
# in this app, and HTTP API's built-in JWT authorizer is the slot Phase 2's
# OAuth decision would plug into.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }

  backend "s3" {
    bucket       = "chess-cloud-tfstate-961868442307"
    key          = "api/terraform.tfstate"
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

variable "lambda_timeout" {
  description = <<-EOT
    The read handlers do sub-second work (one DynamoDB call); the timeout only
    bounds a hung dependency. 10s covers a cold start plus one slow SDK retry,
    while failing a genuinely hung call long before the gateway's 29s cap would
    make the client wait for the same bad news.
  EOT
  type        = number
  default     = 10
}

variable "chesscom_user_agent" {
  description = <<-EOT
    Sent on every request to Chess.com's Published Data API. The API is free
    and unauthenticated, so this header is the only thing identifying us: they
    use it to make contact before blocking an IP. A missing or anonymous UA is
    the difference between an email and a ban, which is why it is configuration
    rather than an optional nicety.
  EOT
  type        = string
  default     = "chess-cloud-project/0.1 (learning project; wenkang.hoo@gmail.com)"
}

variable "submit_timeout" {
  description = <<-EOT
    Submit is no longer a two-call function. It fetches the player's archive
    list from Chess.com, then performs one conditional write per month - up to
    ~150 for a long-lived account - before batching the queue sends ten at a
    time. Those writes are sequential, so the wall clock is real.

    20s leaves headroom for a cold start plus a slow upstream, and still fails
    inside the gateway's 29s cap: past that the client gets a 504 regardless,
    so a longer timeout would only burn Lambda time for news nobody receives.
  EOT
  type        = number
  default     = 20
}

variable "allowed_origins" {
  description = <<-EOT
    Origins the browser app is served from. Only these may call the API with
    JavaScript - a wildcard would let any site on the internet make requests
    using a signed-in user's browser, which the public reads survive but
    POST /games does not.

    A list rather than a single value on purpose: the app runs on localhost in
    development, on the CloudFront URL once deployed, and on a custom domain
    after that. All three can be present at once, so adding a domain never
    means a window where the live origin has been swapped out.
  EOT
  type        = list(string)
  default = [
    "http://localhost:5173",
  ]
}

# The table and queue live in their own roots; their outputs are the contract.
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

data "terraform_remote_state" "guardrails" {
  backend = "s3"
  config = {
    bucket = "chess-cloud-tfstate-961868442307"
    key    = "guardrails/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

data "terraform_remote_state" "auth" {
  backend = "s3"
  config = {
    bucket = "chess-cloud-tfstate-961868442307"
    key    = "auth/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

variable "eval_depth" {
  description = <<-EOT
    Stockfish search depth, mirrored from the worker module. This route uses it
    only to decide which games still need evaluating; the evaluator owns the
    setting itself. The two must agree, or selection queues games the worker
    thinks are done.
  EOT
  type        = number
  default     = 18
}

variable "player_timeout" {
  description = <<-EOT
    Longer than the other read handlers because this one derives evaluation
    state by paginating the player's game items, not just their months. erik is
    230 months and the bulk of ~147k stored games; projecting to three
    attributes keeps that cheap in RCUs but it is still several round trips.

    Still well under the gateway's 29s cap, so a genuinely hung call fails here
    rather than as a gateway timeout with no log line to explain it.
  EOT
  type        = number
  default     = 25
}

variable "analyse_rate_burst" {
  description = <<-EOT
    Tokens in a caller's bucket for POST /analyse. Charged per distinct new
    player, never for a re-submit that queues nothing - the dedup has to stay
    free or the argument for cutting verification stops holding.

    Five rather than one because the product is about comparing players, and a
    flat one-per-hour makes looking at yourself and two friends a three-hour
    job. Sustained use still converges to the refill rate.
  EOT
  type        = number
  default     = 5
}

variable "analyse_rate_refill_seconds" {
  description = <<-EOT
    How long one token takes to come back: the sustained rate for new players.
    At the measured $0.057 worst case per player, one per hour caps a
    determined account at ~$1.37/day.

    This bounds an *account*, and accounts are free - see the registration note
    in PHASE-E.md. The budget alarm remains the real backstop.
  EOT
  type        = number
  default     = 3600
}

variable "analyse_claim_seconds" {
  description = <<-EOT
    How long one player's evaluation run is claimed for, so a second request
    while it is still going returns queued 0 rather than re-queueing every game
    and spending a second token.

    Selection's dedup only sees games the engine has *finished*, so without
    this the whole length of a run is a window in which every queued game still
    looks unevaluated. Measured: a re-submit mid-run made 402 messages for 201
    games and evaluated 17 of them twice.

    Sized to cover a full batch - 201 games on 8 tasks measured at 13.9 min -
    with margin. It expires rather than being cleared, so a crashed run cannot
    wedge a player permanently.
  EOT
  type        = number
  default     = 1200
}

variable "eval_classes" {
  description = <<-EOT
    Time controls worth evaluating. Daily is excluded: a correspondence player
    moves with an engine and a database open, so centipawn loss there measures
    their tools rather than their judgement, and averaging it into a headline
    figure describes two different activities at once.

    Set on both the analyse and player functions from this one variable. They
    must agree - selection decides what to queue, the player route derives what
    is outstanding, and if the rules differ the dashboard shows work pending
    that nothing will ever pick up.
  EOT
  type        = list(string)
  default     = ["bullet", "blitz", "rapid"]
}

variable "eval_games_per_class" {
  description = <<-EOT
    The per-time-control cap, mirrored onto the player route so its derived
    counts use the same denominator selection does.
  EOT
  type        = number
  default     = 100
}

locals {
  table_name = data.terraform_remote_state.data.outputs.table_name
  table_arn  = data.terraform_remote_state.data.outputs.table_arn
  queue_url  = data.terraform_remote_state.queue.outputs.queue_url
  queue_arn  = data.terraform_remote_state.queue.outputs.queue_arn

  eval_queue_url = data.terraform_remote_state.queue.outputs.eval_queue_url
  eval_queue_arn = data.terraform_remote_state.queue.outputs.eval_queue_arn

  handlers_dir = "${path.module}/../../app/handlers"
}

# --- Packaging -------------------------------------------------------------
# Each handler is a single stdlib+boto3 file, so packaging is just zipping it.
# boto3 ships in the Lambda runtime; no dependency layer needed.
#
# output_file_mode is fixed because the zip records each file's mode, and the
# mode depends on the machine: Windows reports 0666, a Linux checkout 0644.
# Unpinned, the same commit hashed differently on the laptop and in CI, so
# each would redeploy all six functions over a permission bit. Line endings
# are the other half of this, pinned in .gitattributes.

data "archive_file" "submit" {
  type             = "zip"
  source_file      = "${local.handlers_dir}/submit.py"
  output_path      = "${path.module}/build/submit.zip"
  output_file_mode = "0644"
}

data "archive_file" "analyse" {
  type             = "zip"
  source_file      = "${local.handlers_dir}/analyse.py"
  output_path      = "${path.module}/build/analyse.zip"
  output_file_mode = "0644"
}

data "archive_file" "status" {
  type             = "zip"
  source_file      = "${local.handlers_dir}/status.py"
  output_path      = "${path.module}/build/status.zip"
  output_file_mode = "0644"
}

data "archive_file" "link" {
  type             = "zip"
  source_file      = "${local.handlers_dir}/link.py"
  output_path      = "${path.module}/build/link.zip"
  output_file_mode = "0644"
}

data "archive_file" "player" {
  type             = "zip"
  source_file      = "${local.handlers_dir}/player.py"
  output_path      = "${path.module}/build/player.zip"
  output_file_mode = "0644"
}

data "archive_file" "players" {
  type             = "zip"
  source_file      = "${local.handlers_dir}/players.py"
  output_path      = "${path.module}/build/players.zip"
  output_file_mode = "0644"
}

# --- Logs ------------------------------------------------------------------
# Created explicitly rather than letting Lambda auto-create them: auto-created
# groups keep logs forever (a slow cost leak), and a pre-existing group is
# what lets the IAM policy name an exact resource instead of a wildcard.

resource "aws_cloudwatch_log_group" "analyse" {
  name              = "/aws/lambda/chess-cloud-analyse"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "submit" {
  name              = "/aws/lambda/chess-cloud-submit"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "link" {
  name              = "/aws/lambda/chess-cloud-link"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "status" {
  name              = "/aws/lambda/chess-cloud-status"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "player" {
  name              = "/aws/lambda/chess-cloud-player"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "players" {
  name              = "/aws/lambda/chess-cloud-players"
  retention_in_days = 14
}

# --- IAM -------------------------------------------------------------------
# One role per function, each naming the exact actions and resources it
# touches. Submit can write the table and send to the queue; status can only
# read the table. Neither can receive or delete queue messages - that is the
# worker's job, and keeping SendMessage the only queue permission here is
# also what keeps redrive the only real path into the DLQ.

# X-Ray: every function traced, so a slow request splits into cold start,
# handler time and Lambda's own overhead. The question it answers: /player
# averaged 4.1 s over 30 days with a 24 s worst against a 25 s timeout, and
# analyse hit its 20 s timeout at least once - the REPORT line gives only the
# total. Tracing alone needs no code or packaging change; timing each DynamoDB
# call would need the X-Ray SDK, which breaks the single-file zips, so that is
# deferred until the traces show the handler itself is the slow part.
#
# ~$0: the free tier is 100k traces a month, and this API serves about 1k.
# X-Ray has no resource-level permissions, hence "*".
locals {
  xray_write = {
    Effect   = "Allow"
    Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    Resource = "*"
  }
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "analyse" {
  name               = "chess-cloud-analyse"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "analyse" {
  name = "analyse"
  role = aws_iam_role.analyse.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        # Query to select the games needing evaluation; GetItem, UpdateItem and
        # DeleteItem for the caller's rate-limit bucket and the per-player
        # in-flight claim. This route still writes no *game* data - the
        # evaluator owns the eval fields, and the route that asks for
        # evaluation has no business modifying them. The only items it writes
        # are USER#<sub> / RATE#analyse and PLAYER#... / ANALYSE#claim.
        #
        # DeleteItem is only ever used to release a claim whose run never
        # started, because the request was rate-limited after claiming.
        Action = [
          "dynamodb:Query",
          "dynamodb:GetItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
        ]
        # The index ARN is separate from the table's: a Query with IndexName
        # against a policy naming only the table is denied.
        Resource = [local.table_arn, "${local.table_arn}/index/by-class"]
      },
      {
        Effect = "Allow"
        # Both, because this fans a player out into one message per game and
        # batches them ten at a time. SendMessageBatch is a distinct IAM
        # action rather than a variant of SendMessage - granting only the
        # latter fails every fan-out, which this project has been caught by
        # once already.
        Action   = ["sqs:SendMessage", "sqs:SendMessageBatch"]
        Resource = local.eval_queue_arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.analyse.arn}:*"
      },
      local.xray_write,
    ]
  })
}

resource "aws_iam_role" "submit" {
  name               = "chess-cloud-submit"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "submit" {
  name = "submit"
  role = aws_iam_role.submit.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        # UpdateItem rather than PutItem, and the distinction is load-bearing:
        # PutItem replaces an item wholesale, so re-claiming a FAILED month
        # would erase its stored ETag and force a full re-download of an
        # archive that had not changed. Setting named attributes preserves it.
        # Still no DeleteItem - submit creates and re-claims, it never removes.
        Action   = ["dynamodb:UpdateItem"]
        Resource = local.table_arn
      },
      {
        Effect = "Allow"
        # SendMessageBatch is a separate IAM action from SendMessage, not a
        # variant of it - granting only the latter fails every fan-out with
        # AccessDenied. Both are listed because the batch call is what submit
        # uses now and the single call is one refactor away from returning.
        Action   = ["sqs:SendMessage", "sqs:SendMessageBatch"]
        Resource = local.queue_arn
      },
      {
        Effect = "Allow"
        # Submit gates on email_verified, which is an *id* token claim - the
        # gateway authorizes the access token, which does not carry it. So the
        # user is looked up instead. Read-only: this grants no ability to
        # create, modify or delete a user.
        Action   = ["cognito-idp:AdminGetUser"]
        Resource = data.terraform_remote_state.auth.outputs.user_pool_arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.submit.arn}:*"
      },
      local.xray_write,
    ]
  })
}

resource "aws_iam_role" "link" {
  name               = "chess-cloud-link"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "link" {
  name = "link"
  role = aws_iam_role.link.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        # PutItem writes both the link and the pending OAuth state; GetItem and
        # Query read them back; DeleteItem consumes the state so a callback
        # cannot be replayed. Scan is here only for the state lookup, which has
        # no key other than the unguessable state value - see link.py.
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:Query",
          "dynamodb:Scan",
          "dynamodb:DeleteItem",
        ]
        Resource = local.table_arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.link.arn}:*"
      },
      local.xray_write,
    ]
  })
}

resource "aws_iam_role" "player" {
  name               = "chess-cloud-player"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "player" {
  name = "player"
  role = aws_iam_role.player.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        # Query for the months and the by-class index: every month for a
        # player shares one partition key, so the whole history is a single
        # Query. GetItem only for analyse's per-player claim, so the page can
        # tell a run in flight from games nobody has queued. No Scan.
        Action = ["dynamodb:Query", "dynamodb:GetItem"]
        # The index ARN is separate from the table's: a Query with IndexName
        # against a policy naming only the table is denied.
        Resource = [local.table_arn, "${local.table_arn}/index/by-class"]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.player.arn}:*"
      },
      local.xray_write,
    ]
  })
}

resource "aws_iam_role" "players" {
  name               = "chess-cloud-players"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "players" {
  name = "players"
  role = aws_iam_role.players.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        # Scan, and the only route in the project that gets it. "List all
        # players" has no partition key, so the primary key cannot answer it -
        # this reads the whole table and discards most of what it reads.
        #
        # Granted knowingly and temporarily. The cost of a Scan grows with
        # total items rather than with the number of players, so one busy
        # account adds ~200 archive items that this route must read on every
        # call. The fix is a GSI keyed for listing, at which point this becomes
        # Query and the permission goes back to matching every other read role.
        Action   = ["dynamodb:Scan"]
        Resource = local.table_arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.players.arn}:*"
      },
      local.xray_write,
    ]
  })
}

resource "aws_iam_role" "status" {
  name               = "chess-cloud-status"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "status" {
  name = "status"
  role = aws_iam_role.status.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        # GetItem for the month, Query for its games. Games are their own
        # items now, so reading a month is one GetItem plus a paginated Query
        # over the GAME# prefix - a distinct IAM action, and read-only either
        # way. Still no write of any kind: status reads.
        Action   = ["dynamodb:GetItem", "dynamodb:Query"]
        Resource = local.table_arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.status.arn}:*"
      },
      local.xray_write,
    ]
  })
}

# --- Functions -------------------------------------------------------------

resource "aws_lambda_function" "analyse" {
  function_name = "chess-cloud-analyse"
  role          = aws_iam_role.analyse.arn

  filename         = data.archive_file.analyse.output_path
  source_code_hash = data.archive_file.analyse.output_base64sha256

  runtime = "python3.13"
  handler = "analyse.handler"

  # JSON logs from the runtime itself: stdlib logging calls become one
  # JSON object per line with requestId stamped on, and START/END/REPORT
  # become JSON too. The workers' formatter copies these key names, so one
  # query spans every log group. See app/worker/jsonlog.py.
  logging_config {
    log_format            = "JSON"
    application_log_level = "INFO"
    system_log_level      = "INFO"
  }
  tracing_config {
    mode = "Active"
  }
  # Paginates a player's games and fans out up to 400 messages in batches of
  # ten. Still no outbound HTTP, but more work than a read handler - sized
  # like submit, which does the same shape of fan-out over archives.
  timeout = 20

  environment {
    variables = {
      TABLE_NAME     = local.table_name
      EVAL_QUEUE_URL = local.eval_queue_url
      # Must match the evaluator's, or selection would queue games the worker
      # considers done, or skip games it would redo.
      EVAL_DEPTH           = tostring(var.eval_depth)
      EVAL_CLASSES         = join(",", var.eval_classes)
      EVAL_GAMES_PER_CLASS = tostring(var.eval_games_per_class)

      ANALYSE_RATE_BURST          = tostring(var.analyse_rate_burst)
      ANALYSE_RATE_REFILL_SECONDS = tostring(var.analyse_rate_refill_seconds)
      ANALYSE_CLAIM_SECONDS       = tostring(var.analyse_claim_seconds)
    }
  }

  depends_on = [aws_cloudwatch_log_group.analyse]
}

resource "aws_lambda_function" "submit" {
  function_name = "chess-cloud-submit"
  role          = aws_iam_role.submit.arn

  filename         = data.archive_file.submit.output_path
  source_code_hash = data.archive_file.submit.output_base64sha256

  runtime = "python3.13"
  handler = "submit.handler"

  logging_config {
    log_format            = "JSON"
    application_log_level = "INFO"
    system_log_level      = "INFO"
  }
  tracing_config {
    mode = "Active"
  }
  timeout = var.submit_timeout

  environment {
    variables = {
      TABLE_NAME   = local.table_name
      QUEUE_URL    = local.queue_url
      USER_POOL_ID = data.terraform_remote_state.auth.outputs.user_pool_id
      # Chess.com's API is unauthenticated, so this header is the only thing
      # identifying us to them. Set here rather than hardcoded so the contact
      # address can change without a code deploy.
      CHESSCOM_USER_AGENT = var.chesscom_user_agent
    }
  }

  # Without this, a cold start racing the first log write could auto-create
  # the group before Terraform does, with retention set to "never expire".
  depends_on = [aws_cloudwatch_log_group.submit]
}

resource "aws_lambda_function" "link" {
  function_name = "chess-cloud-link"
  role          = aws_iam_role.link.arn

  filename         = data.archive_file.link.output_path
  source_code_hash = data.archive_file.link.output_base64sha256

  runtime = "python3.13"
  handler = "link.handler"

  logging_config {
    log_format            = "JSON"
    application_log_level = "INFO"
    system_log_level      = "INFO"
  }
  tracing_config {
    mode = "Active"
  }
  # Longer than the others: this one makes two outbound calls to lichess.org
  # (token exchange, then account lookup) and a slow upstream should fail the
  # request rather than the function.
  timeout = 20

  environment {
    variables = {
      TABLE_NAME = local.table_name
      # The redirect_uri must match byte-for-byte between the authorize request
      # and the token exchange, so it is derived from one value. invoke_url
      # carries a trailing slash; strip it or every URL built from this gets a
      # doubled separator, which OAuth compares as a different URI.
      API_BASE = trimsuffix(aws_apigatewayv2_stage.default.invoke_url, "/")
    }
  }

  depends_on = [aws_cloudwatch_log_group.link]
}

resource "aws_lambda_function" "player" {
  function_name = "chess-cloud-player"
  role          = aws_iam_role.player.arn

  filename         = data.archive_file.player.output_path
  source_code_hash = data.archive_file.player.output_base64sha256

  runtime = "python3.13"
  handler = "player.handler"

  logging_config {
    log_format            = "JSON"
    application_log_level = "INFO"
    system_log_level      = "INFO"
  }
  tracing_config {
    mode = "Active"
  }
  # Not var.lambda_timeout: that is sized for one DynamoDB call, and this
  # route now paginates a second Query across the player's whole game
  # partition to derive evaluation state. A heavy account is tens of thousands
  # of rows even projected down to three attributes.
  timeout = var.player_timeout

  environment {
    variables = {
      TABLE_NAME = local.table_name
      # This route derives evaluation state from the game items rather than
      # reading it off the month, so it needs the same three settings
      # selection uses. Disagreement here is silent: the counts would simply
      # be wrong, with no error anywhere.
      EVAL_DEPTH           = tostring(var.eval_depth)
      EVAL_CLASSES         = join(",", var.eval_classes)
      EVAL_GAMES_PER_CLASS = tostring(var.eval_games_per_class)
    }
  }

  depends_on = [aws_cloudwatch_log_group.player]
}

resource "aws_lambda_function" "players" {
  function_name = "chess-cloud-players"
  role          = aws_iam_role.players.arn

  filename         = data.archive_file.players.output_path
  source_code_hash = data.archive_file.players.output_base64sha256

  runtime = "python3.13"
  handler = "players.handler"

  logging_config {
    log_format            = "JSON"
    application_log_level = "INFO"
    system_log_level      = "INFO"
  }
  tracing_config {
    mode = "Active"
  }
  # Longer than the other reads: a Scan pages through the entire table, and
  # while that is fast at the current size it is the one read whose duration
  # grows with everything ever ingested rather than with what it returns.
  timeout = 20

  environment {
    variables = {
      TABLE_NAME = local.table_name
    }
  }

  depends_on = [aws_cloudwatch_log_group.players]
}

resource "aws_lambda_function" "status" {
  function_name = "chess-cloud-status"
  role          = aws_iam_role.status.arn

  filename         = data.archive_file.status.output_path
  source_code_hash = data.archive_file.status.output_base64sha256

  runtime = "python3.13"
  handler = "status.handler"

  logging_config {
    log_format            = "JSON"
    application_log_level = "INFO"
    system_log_level      = "INFO"
  }
  tracing_config {
    mode = "Active"
  }
  timeout = var.lambda_timeout

  environment {
    variables = {
      TABLE_NAME = local.table_name
    }
  }

  depends_on = [aws_cloudwatch_log_group.status]
}

# --- API Gateway -----------------------------------------------------------

resource "aws_apigatewayv2_api" "api" {
  name          = "chess-cloud"
  protocol_type = "HTTP"

  # CORS exists only because the client became a browser. curl and the drill
  # scripts never needed it: the same-origin policy is enforced by browsers, so
  # it constrains page JavaScript rather than the API. Without this, a fetch
  # from the React app is blocked by the browser *after* the API has already
  # answered - the request succeeds and the response is thrown away, which is
  # why the symptom is a console error rather than a 4xx.
  #
  # API Gateway answers the preflight OPTIONS itself, so no Lambda runs for it.
  cors_configuration {
    # Explicit origins, not "*". A wildcard would let any site on the internet
    # call this API with a user's browser - harmless for the public reads, not
    # harmless for POST /games. The list carries every origin the app is served
    # from, which is what lets a custom domain be added later without
    # swapping the CloudFront one out mid-migration.
    allow_origins = var.allowed_origins

    allow_methods = ["GET", "POST", "OPTIONS"]

    # Authorization is the one that matters: without it the browser strips the
    # bearer token from cross-origin requests and every authenticated call
    # arrives at the gateway looking unauthenticated.
    allow_headers = ["Authorization", "Content-Type"]

    # How long a browser may cache the preflight result. An hour means one
    # OPTIONS per browser per session rather than one before every POST.
    max_age = 3600
  }
}

resource "aws_apigatewayv2_integration" "submit" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.submit.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "analyse" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.analyse.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "status" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.status.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "player" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.player.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "players" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.players.invoke_arn
  payload_format_version = "2.0"
}

# --- Authorizer ------------------------------------------------------------

# The lock on the front door. API Gateway validates the JWT itself - signature
# against the pool's published JWKS, plus issuer, audience and expiry - and
# rejects with 401 before any integration runs. An unauthenticated request
# therefore costs zero Lambda invocations, which is the whole reason this is a
# gateway concern rather than a check at the top of each handler.
#
# Note what this does NOT do: it gates the *caller*, not what the functions may
# touch. The execution roles are unchanged - see the IAM section in CLAUDE.md.
resource "aws_apigatewayv2_authorizer" "jwt" {
  api_id           = aws_apigatewayv2_api.api.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "cognito"

  jwt_configuration {
    # The access token's audience is the app client id. Checking it stops a
    # token minted for some other client of the same pool being replayed here.
    audience = [data.terraform_remote_state.auth.outputs.user_pool_client_id]
    issuer   = data.terraform_remote_state.auth.outputs.issuer
  }
}

# Authenticated, like submit and for the same reason: it spends money. The
# read routes stay public because analysis is public shared data.
resource "aws_apigatewayv2_route" "analyse" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "POST /analyse"
  target    = "integrations/${aws_apigatewayv2_integration.analyse.id}"

  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.jwt.id
}

resource "aws_apigatewayv2_route" "submit" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "POST /games"
  target    = "integrations/${aws_apigatewayv2_integration.submit.id}"

  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.jwt.id
}

# Three path segments rather than one opaque id: the analysis id is
# platform/username/yyyy-mm, and splitting it here means a slash inside the id
# needs no escaping by the client.
#
# Deliberately unauthenticated. Analysis results are public - the product is
# looking at any player's skill across many games, so anyone may read anyone's
# profile. Requiring a token would have been security theatre: the underlying
# data comes from Chess.com's Published Data API, which serves it to anyone
# without a token, so a lock here protects nothing that is not already open.
#
# What still bounds it is the stage throttle, which is now the only limit on
# this route. That is the trade being made knowingly: reads are cheap, the
# data is public, and 10 req/s caps what any one caller can cost.
resource "aws_apigatewayv2_route" "status" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "GET /analysis/{platform}/{username}/{archive}"
  target    = "integrations/${aws_apigatewayv2_integration.status.id}"
}

# The route submit points a client at. Since submit fans a username out into
# ~150 independent months, this is what makes the job legible: one Query
# returns every month with its own status plus cumulative totals over the ones
# that are done, so a partial history reads as progress rather than absence.
#
# It returns per-month summaries but not the games - 152 months of games would
# be tens of megabytes. Drilling into a month is what the status route above is
# for, which is why both exist.
#
# Unauthenticated for the same reason as the status route: analysis is public.
resource "aws_apigatewayv2_route" "player" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "GET /player/{platform}/{username}"
  target    = "integrations/${aws_apigatewayv2_integration.player.id}"
}

# The directory: every player anyone has ever submitted. Unauthenticated like
# the other reads, and that is a slightly larger statement than it was for the
# per-player routes - those require you to already know a username, this one
# hands out the list. It is consistent with analysis being public shared data
# (Phase 2's decision), but it is the route that makes "public" visible rather
# than merely true, so it is worth stating rather than inheriting.
resource "aws_apigatewayv2_route" "players" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "GET /players"
  target    = "integrations/${aws_apigatewayv2_integration.players.id}"
}

resource "aws_apigatewayv2_integration" "link" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.link.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "link_lichess_start" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "POST /link/lichess"
  target    = "integrations/${aws_apigatewayv2_integration.link.id}"

  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.jwt.id
}

# Deliberately unauthenticated, and the only route that is. Lichess redirects
# the user's *browser* here after they approve, and a redirect carries no
# Authorization header - there is no way for the caller to present a token.
#
# What stands in for it: the `state` parameter. It is 32 bytes of entropy that
# this API generated and stored against the user's own partition moments
# earlier, so possessing a valid one is itself the proof of who is returning.
# The item is single-use (deleted on success) and expires in 10 minutes, so a
# leaked state is neither replayable nor durable.
resource "aws_apigatewayv2_route" "link_lichess_callback" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "GET /link/lichess/callback"
  target    = "integrations/${aws_apigatewayv2_integration.link.id}"
}

resource "aws_apigatewayv2_route" "link_chesscom" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "POST /link/chesscom"
  target    = "integrations/${aws_apigatewayv2_integration.link.id}"

  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.jwt.id
}

resource "aws_apigatewayv2_route" "links_list" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "GET /links"
  target    = "integrations/${aws_apigatewayv2_integration.link.id}"

  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.jwt.id
}

resource "aws_lambda_permission" "link" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.link.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true

  # Two jobs now, both real. On the authenticated routes it bounds one
  # caller's blast radius: a runaway polling loop or a compromised account
  # cannot run up a Lambda bill. On the public read route it is the *only*
  # limit, since anyone may call that without a token - which is the trade
  # accepted when analysis became public. The account default is 10,000 req/s,
  # so without this the ceiling is "whatever a script can manage".
  default_route_settings {
    throttling_rate_limit  = 10
    throttling_burst_limit = 20
  }
}

# Lets API Gateway invoke the functions - scoped to this API's execution ARN,
# so no other API (or account) can trigger them.
resource "aws_lambda_permission" "analyse" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.analyse.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

resource "aws_lambda_permission" "submit" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.submit.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

resource "aws_lambda_permission" "status" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.status.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

resource "aws_lambda_permission" "player" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.player.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

resource "aws_lambda_permission" "players" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.players.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

# --- Errors alarm -----------------------------------------------------------

# A request that crashed or timed out. Found by X-Ray's first look: analyse
# had hit its 20 s timeout and nothing said so - the user got a 500 and the
# only record was a REPORT line nobody reads.
#
# Lambda's account-wide Errors, with no FunctionName dimension: one alarm and
# one metric covers every function, stays inside the free ten, and a function
# added later is covered without touching this. The email does not name the
# function; the logs do. Every Lambda in this account is this project's.
#
# The query in the description was wrong the first time and only the drill
# showed it: the runtime logs an unhandled exception under `log_level`, not the
# `level` the app's own lines use, and in JSON format a timeout is not the
# "Task timed out" text but `status: timeout` on platform.report - while a
# crash's report says `status: success`. Hence all three terms.
#
# Counts unhandled exceptions and timeouts. Deliberately not counted: the
# handled 502/503s that submit and link return when Chess.com or Lichess is
# down - an upstream outage is not something to act on at 2am.
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "chess-cloud-lambda-errors"
  alarm_description   = "A Lambda crashed or timed out. Find which - Logs Insights over /aws/lambda/chess-cloud-*: filter log_level = 'ERROR' or level = 'ERROR' or record.status in ['timeout', 'error', 'failure']"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"

  # No invocations publishes nothing, which is the normal state.
  treat_missing_data = "notBreaching"

  alarm_actions = [data.terraform_remote_state.guardrails.outputs.alerts_topic_arn]
  ok_actions    = [data.terraform_remote_state.guardrails.outputs.alerts_topic_arn]
}

output "api_endpoint" {
  description = <<-EOT
    Base URL. POST /games with {"username": "..."} to submit a whole player,
    GET /player/{platform}/{username} to poll, and
    GET /analysis/{platform}/{username}/{yyyy-mm} for one month with its games.
  EOT
  value       = aws_apigatewayv2_api.api.api_endpoint
}
