# Web: where the frontend will be served from. For now, only DNS.
#
# The domain is registered at Porkbun, not Route 53 - this account's Route 53
# registration was refused ("We can't finish registering your domain") and the
# support case went unanswered. See the Deviations table in CLAUDE.md. The
# registrar only holds the name and points it here; every record lives in this
# zone, so the certificate, CloudFront and the rest stay in Terraform.
#
# The one manual link: Porkbun's nameservers for the domain must be set to
# this zone's name_servers output. Terraform cannot see that setting.

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
    key          = "web/terraform.tfstate"
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

variable "domain" {
  description = "The site's domain, registered at Porkbun."
  type        = string
  default     = "hoowenkang.com"
}

# $0.50/month. Recreating it would assign four new nameservers, and the domain
# would stop resolving until Porkbun was updated by hand - so Terraform refuses
# to destroy it rather than let a plan replace it quietly.
resource "aws_route53_zone" "site" {
  name    = var.domain
  comment = "chess-cloud frontend. Delegated from Porkbun."

  lifecycle {
    prevent_destroy = true
  }
}

# Copy these four into Porkbun's "Authoritative Nameservers" for the domain.
output "name_servers" {
  value = aws_route53_zone.site.name_servers
}

output "zone_id" {
  value = aws_route53_zone.site.zone_id
}
