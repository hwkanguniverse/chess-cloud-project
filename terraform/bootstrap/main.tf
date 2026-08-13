# Bootstrap: creates the S3 bucket that holds Terraform state for everything else.
#
# This config deliberately uses LOCAL state. The bucket cannot be stored in the
# bucket it creates, so this one config stays local while every other config
# uses the S3 backend. Run once, then leave alone.

terraform {
  required_version = ">= 1.10" # use_lockfile (native S3 locking) needs 1.10+

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
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
  description = "AWS region. Matches the cost model in the aws-cert-plan roadmap."
  type        = string
  default     = "ap-southeast-1"
}

variable "state_bucket_name" {
  description = "Globally unique name for the Terraform state bucket."
  type        = string
  default     = "chess-cloud-tfstate-961868442307"
}

resource "aws_s3_bucket" "tfstate" {
  bucket = var.state_bucket_name

  # State is the record of everything built. Losing it means losing the ability
  # to manage or destroy the infrastructure it tracks.
  lifecycle {
    prevent_destroy = true
  }
}

# Recovers state from a corrupt write or a bad apply. The setting that matters most.
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

# State holds every attribute of every resource, secrets included. Never public.
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Old state versions accumulate with every apply. Nothing needs them after a
# few months, and they are the only thing that grows unbounded here.
resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

output "state_bucket" {
  description = "Bucket name to reference in other configs' backend blocks."
  value       = aws_s3_bucket.tfstate.id
}
