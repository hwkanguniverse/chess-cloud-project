# Identity: a Cognito user pool in front of the API.
#
# Phase 1's API is open - anyone holding a game id can read that game. Ids are
# hard to guess, which is not access control. This stack issues the tokens the
# API Gateway authorizer checks, so the API can know *who* is asking.
#
# Separate root from api/ on purpose. The two have opposite lifecycles: the
# Lambdas are redeployed on every code change, while a user pool holds real
# accounts and must never be casually destroyed. Keeping them apart means
# iterating on handler code can never take the account directory with it.

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
    key          = "auth/terraform.tfstate"
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

variable "access_token_hours" {
  description = <<-EOT
    Lifetime of the access token the authorizer validates.

    This is the revocation window, and it is the whole trade-off. The
    authorizer verifies the signature offline and never calls Cognito, so a
    token stays valid until it expires even if the user is deleted mid-flight.
    One hour bounds that exposure while keeping refreshes rare enough that the
    client is not constantly round-tripping.
  EOT
  type        = number
  default     = 1
}

variable "refresh_token_days" {
  description = <<-EOT
    Lifetime of the refresh token, i.e. how long before a user must log in
    again. Unlike the access token this *is* checked against Cognito on every
    use, so it can be revoked - which is what makes a long value acceptable.
  EOT
  type        = number
  default     = 30
}

# --- User pool -------------------------------------------------------------

resource "aws_cognito_user_pool" "main" {
  name = "chess-cloud"

  # Email as the username. The alternative - a separate username field - buys
  # nothing here and gives users a second credential to forget. The chess
  # username is deliberately NOT this: it is a linked account (see the linking
  # work in CLAUDE.md), not the identity, because the app cannot verify it.
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  # LITE is the cheapest tier and covers password sign-in, the hosted UI and
  # JWT issuance - everything this phase needs. ESSENTIALS/PLUS add features
  # (advanced security, threat protection) with a per-MAU price and no failure
  # mode here that would justify them.
  user_pool_tier = "LITE"

  # No MFA. For a personal app over public chess data there is no failure mode
  # that justifies the setup cost or the recovery burden of a lost device. This
  # is a deliberate cut, not an oversight - revisit if the app ever holds
  # anything a stranger would want.
  mfa_configuration = "OFF"

  password_policy {
    minimum_length    = 12
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true

    # Symbols are omitted on purpose. Length beats character-class rules for
    # real entropy, and symbol requirements mostly produce "Password1!" plus a
    # sticky note.
    require_symbols = false
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # Cognito's own email sender, capped at 50/day. Fine for a personal project;
  # SES is the answer if that ceiling is ever hit, and is not worth wiring now.
  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  # The pool holds real user accounts. Everything else in this project is
  # rebuildable from code - this is not, so make an accidental destroy fail.
  deletion_protection = "ACTIVE"
}

# --- App client ------------------------------------------------------------

# Public client: no secret. The client here is a browser page, and a secret
# shipped to a browser is not a secret. PKCE covers the exchange instead, which
# is why this phase needs no Secrets Manager entry - see CLAUDE.md.
resource "aws_cognito_user_pool_client" "web" {
  name         = "chess-cloud-web"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret = false

  # No OAuth flows and no hosted UI. The app signs in with SRP through Amplify,
  # which renders sign-in, sign-up, confirmation and password reset itself, so
  # the authorization-code path was a second way into this pool that nothing
  # used - a publicly reachable signup page the app did not control. Removed
  # rather than left dormant; see PHASE-F.md.
  #
  # Set empty rather than omitted. Dropping these attributes from the config
  # leaves whatever was last applied in place, so the client kept advertising
  # the code flow and a localhost callback after the domain was destroyed -
  # inert without a domain, but exactly the stale config that misleads someone
  # reading the console later.
  allowed_oauth_flows                  = []
  allowed_oauth_scopes                 = []
  allowed_oauth_flows_user_pool_client = false
  callback_urls                        = []
  logout_urls                          = []

  supported_identity_providers = ["COGNITO"]

  access_token_validity  = var.access_token_hours
  id_token_validity      = var.access_token_hours
  refresh_token_validity = var.refresh_token_days

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  # Lets a signed-out refresh token be revoked, which is the only way to cut a
  # session short given the access token is validated offline.
  enable_token_revocation = true

  # Return a generic "incorrect username or password" rather than confirming
  # which half was wrong. Otherwise the login form doubles as an oracle for
  # which email addresses have accounts.
  prevent_user_existence_errors = "ENABLED"

  # SRP for the login itself and refresh for renewal. USER_PASSWORD_AUTH is
  # excluded deliberately: it sends the raw password to the API, where SRP
  # proves knowledge of it without transmitting it.
  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]
}

# --- Outputs ---------------------------------------------------------------

output "user_pool_id" {
  description = "User pool id."
  value       = aws_cognito_user_pool.main.id
}

output "user_pool_client_id" {
  description = "App client id. Public - no secret to protect."
  value       = aws_cognito_user_pool_client.web.id
}

output "issuer" {
  description = "JWT issuer URL. The API authorizer validates tokens against this."
  value       = "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
}
