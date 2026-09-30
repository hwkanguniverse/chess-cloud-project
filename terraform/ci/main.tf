# CI: the identity GitHub Actions deploys as.
#
# GitHub signs a short-lived token for each workflow run, saying which repo,
# branch and event it came from. AWS trusts GitHub's signature (the OIDC
# provider below) and swaps that token for credentials that expire within the
# hour. No AWS key is stored in GitHub - there is nothing long-lived to leak.
#
# Applied by hand, like bootstrap. CI cannot create the role it logs in with,
# and a pipeline able to edit its own trust policy could widen it.

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
    key          = "ci/terraform.tfstate"
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

# The repository as GitHub names it in the token's subject. This repo uses
# GitHub's immutable subject format: owner and repo each carry their numeric
# ID (owner@id/repo@id). Found by the first run being refused - CloudTrail
# showed the subject GitHub actually sent. It is the stronger form: a name can
# be renamed away and re-registered by someone else, an ID cannot, so a trust
# policy on IDs cannot be inherited by a lookalike repo. Read the current
# value from GET /repos/{owner}/{repo}/actions/oidc/customization/sub.
variable "github_subject_repo" {
  description = "Subject prefix of the only repository allowed to assume these roles."
  type        = string
  default     = "hwkanguniverse@8513534/chess-cloud-project@1332943637"
}

locals {
  issuer = "token.actions.githubusercontent.com"
}

# One per account per issuer. No thumbprint: AWS verifies GitHub's certificate
# against its own trusted CAs for this issuer, so a pinned thumbprint would
# only be something to go stale.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://${local.issuer}"
  client_id_list = ["sts.amazonaws.com"]
}

# The trust policy is the control. Both roles require the token's audience to
# be STS and its subject to name this repo exactly - StringEquals, never
# StringLike, because one wildcard in `sub` (repo:*, or a branch pattern) is
# the loosening that would keep every workflow working while letting anything
# else in too. check-drift.sh asserts these conditions.
data "aws_iam_policy_document" "trust" {
  for_each = {
    # Pull requests plan. GitHub's subject for a pull_request event carries no
    # branch - every PR in this repo gets the same one.
    plan = "repo:${var.github_subject_repo}:pull_request"
    # Only main applies. A push to any other branch has a different subject,
    # so a workflow committed to a branch cannot reach this role.
    apply = "repo:${var.github_subject_repo}:ref:refs/heads/main"
  }

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.issuer}:sub"
      values   = [each.value]
    }
  }
}

# Read-only. Plans every root on a PR, which means reading state and
# describing every resource. It never takes the state lock (plans run with
# -lock=false), so it needs no write anywhere. Reading state is reading every
# attribute of every resource - acceptable because no secrets exist here.
resource "aws_iam_role" "plan" {
  name               = "chess-cloud-ci-plan"
  assume_role_policy = data.aws_iam_policy_document.trust["plan"].json
}

resource "aws_iam_role_policy_attachment" "plan" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# Admin, by decision (see CLAUDE.md). Terraform here writes IAM, so any role
# that applies it can grant itself admin whatever its own policy says - a
# hand-scoped list would be admin with extra steps. The containment is who can
# assume it: the trust policy above.
resource "aws_iam_role" "apply" {
  name               = "chess-cloud-ci-apply"
  assume_role_policy = data.aws_iam_policy_document.trust["apply"].json
}

resource "aws_iam_role_policy_attachment" "apply" {
  role       = aws_iam_role.apply.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

output "plan_role_arn" {
  value = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  value = aws_iam_role.apply.arn
}
