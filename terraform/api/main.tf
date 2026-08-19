# Front door: an API Gateway HTTP API in front of two thin Lambdas.
#
#   POST /games       -> submit: write PENDING item, queue a message, 202
#   GET  /games/{id}  -> status: one GetItem, the URL the client polls
#
# Neither function does real work. Analysis takes 30-90s and API Gateway caps
# every request at 29s regardless of Lambda's own timeout - the queue is what
# that ceiling forces.
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
    Both handlers do sub-second work (one DynamoDB call, one SQS call); the
    timeout only bounds a hung dependency. 10s covers a cold start plus one
    slow SDK retry, while failing a genuinely hung call long before the
    gateway's 29s cap would make the client wait for the same bad news.
  EOT
  type        = number
  default     = 10
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

data "terraform_remote_state" "auth" {
  backend = "s3"
  config = {
    bucket = "chess-cloud-tfstate-961868442307"
    key    = "auth/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

locals {
  table_name = data.terraform_remote_state.data.outputs.table_name
  table_arn  = data.terraform_remote_state.data.outputs.table_arn
  queue_url  = data.terraform_remote_state.queue.outputs.queue_url
  queue_arn  = data.terraform_remote_state.queue.outputs.queue_arn

  handlers_dir = "${path.module}/../../app/handlers"
}

# --- Packaging -------------------------------------------------------------
# Each handler is a single stdlib+boto3 file, so packaging is just zipping it.
# boto3 ships in the Lambda runtime; no dependency layer needed.

data "archive_file" "submit" {
  type        = "zip"
  source_file = "${local.handlers_dir}/submit.py"
  output_path = "${path.module}/build/submit.zip"
}

data "archive_file" "status" {
  type        = "zip"
  source_file = "${local.handlers_dir}/status.py"
  output_path = "${path.module}/build/status.zip"
}

data "archive_file" "link" {
  type        = "zip"
  source_file = "${local.handlers_dir}/link.py"
  output_path = "${path.module}/build/link.zip"
}

# --- Logs ------------------------------------------------------------------
# Created explicitly rather than letting Lambda auto-create them: auto-created
# groups keep logs forever (a slow cost leak), and a pre-existing group is
# what lets the IAM policy name an exact resource instead of a wildcard.

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

# --- IAM -------------------------------------------------------------------
# One role per function, each naming the exact actions and resources it
# touches. Submit can write the table and send to the queue; status can only
# read the table. Neither can receive or delete queue messages - that is the
# worker's job, and keeping SendMessage the only queue permission here is
# also what keeps redrive the only real path into the DLQ.

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
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
        Effect   = "Allow"
        # GetItem alongside PutItem: the conditional insert fails when the
        # player-month is already known, and the dedup path then reads the
        # existing item to report its status back. Still no UpdateItem or
        # DeleteItem - submit creates, it never mutates.
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem"]
        Resource = local.table_arn
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = local.queue_arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.submit.arn}:*"
      },
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
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem"]
        Resource = local.table_arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.status.arn}:*"
      },
    ]
  })
}

# --- Functions -------------------------------------------------------------

resource "aws_lambda_function" "submit" {
  function_name = "chess-cloud-submit"
  role          = aws_iam_role.submit.arn

  filename         = data.archive_file.submit.output_path
  source_code_hash = data.archive_file.submit.output_base64sha256

  runtime = "python3.13"
  handler = "submit.handler"
  timeout = var.lambda_timeout

  environment {
    variables = {
      TABLE_NAME = local.table_name
      QUEUE_URL  = local.queue_url
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

resource "aws_lambda_function" "status" {
  function_name = "chess-cloud-status"
  role          = aws_iam_role.status.arn

  filename         = data.archive_file.status.output_path
  source_code_hash = data.archive_file.status.output_base64sha256

  runtime = "python3.13"
  handler = "status.handler"
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
}

resource "aws_apigatewayv2_integration" "submit" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.submit.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "status" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.status.invoke_arn
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
resource "aws_apigatewayv2_route" "status" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "GET /analysis/{platform}/{username}/{archive}"
  target    = "integrations/${aws_apigatewayv2_integration.status.id}"

  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.jwt.id
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

  # Kept after the authorizer landed, with a different job. It no longer guards
  # against anonymous hammering - the authorizer rejects that at 401 for free.
  # What is left is a blast radius limit on an *authenticated* caller: a bug in
  # the client's polling loop, or one compromised account, still cannot run up
  # a Lambda bill. The account default is 10,000 req/s, so without this the
  # ceiling is effectively "whatever a script can manage".
  default_route_settings {
    throttling_rate_limit  = 10
    throttling_burst_limit = 20
  }
}

# Lets API Gateway invoke the functions - scoped to this API's execution ARN,
# so no other API (or account) can trigger them.
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

output "api_endpoint" {
  description = "Base URL. POST /games to submit, GET /games/{id} to poll."
  value       = aws_apigatewayv2_api.api.api_endpoint
}
