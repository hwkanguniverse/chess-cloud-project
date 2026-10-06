# Web: where the browser app is served from - chess.hoowenkang.com.
#
# Planned as a private S3 bucket behind CloudFront, with a certificate and DNS
# in a Route 53 zone this root manages. Served from GitHub Pages until the
# account is verified for CloudFront - see cloudfront_enabled. Decided in Phase F
# (see PHASE-F.md, "Hosting"): S3 website hosting alone is HTTP-only, and a
# login flow needs HTTPS on a real origin.
#
# The files themselves are not Terraform's: the apply workflow builds the app
# and syncs it here after this root is applied. Terraform owns the place, CI
# owns the contents - the same split as the worker image and its ECR repo.
#
# The domain is registered at Porkbun, not Route 53 - this account's Route 53
# registration was refused ("We can't finish registering your domain") and the
# support case went unanswered. See the Deviations table in CLAUDE.md. The
# registrar only holds the name and points it here; every record lives in the
# zone below. The one manual link: Porkbun's nameservers for the domain must be
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

# CloudFront reads certificates from us-east-1 only, whatever region the rest
# of the stack is in. Phase F named this as the most common way this setup
# fails, so the certificate is the one resource here pinned to this provider.
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

variable "domain_name" {
  description = <<-EOT
    The registered domain. Registered by hand at Porkbun - a registration is a
    purchase in a person's name, not infrastructure to rebuild from code - and
    delegated to the zone below.
  EOT
  type        = string
  default     = "hoowenkang.com"
}

variable "app_subdomain" {
  description = <<-EOT
    The app lives on a subdomain so the bare domain stays free for a portfolio
    home and every later project gets its own name under it.
  EOT
  type        = string
  default     = "chess"
}

# Off until AWS Support verifies the account. Creating the distribution was
# refused with "Your account must be verified before you can add new
# CloudFront resources" - the same block that refused the Route 53
# registration. Until then the app is served by GitHub Pages through a CNAME
# below. The bucket, origin access control and certificate stay: they cost
# nothing idle, and turning this on is the whole switch back.
variable "cloudfront_enabled" {
  description = "Serve the app from CloudFront (true) or GitHub Pages (false)."
  type        = bool
  default     = false
}

# GitHub's domain-verification TXT value, from github.com/settings/pages.
# Not a secret - it is published in DNS. Verifying the domain on the account
# stops anyone else claiming chess.hoowenkang.com for their own Pages site if
# ours is ever switched off while the CNAME still points at GitHub.
variable "github_pages_verification" {
  description = "TXT value for _github-pages-challenge-<owner>.<domain>."
  type        = string
  default     = ""
}

variable "github_owner" {
  description = "GitHub account that publishes the Pages site."
  type        = string
  default     = "hwkanguniverse"
}

locals {
  app_domain = "${var.app_subdomain}.${var.domain_name}"
}

# $0.50/month. Recreating it would assign four new nameservers, and the domain
# would stop resolving until Porkbun was updated by hand - so Terraform refuses
# to destroy it rather than let a plan replace it quietly.
resource "aws_route53_zone" "site" {
  name    = var.domain_name
  comment = "chess-cloud frontend. Delegated from Porkbun."

  lifecycle {
    prevent_destroy = true
  }
}

# --- Bucket --------------------------------------------------------------------

# Private: no public access, no website hosting. CloudFront reads it through
# Origin Access Control, so the only way to the files is the HTTPS edge.
resource "aws_s3_bucket" "site" {
  bucket        = "chess-cloud-web-961868442307"
  force_destroy = true # built artifacts, rebuilt by every deploy
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "chess-cloud-web"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Only this distribution may read the bucket - the SourceArn condition is what
# stops any other CloudFront distribution, in any account, from using it.
resource "aws_s3_bucket_policy" "site" {
  count  = var.cloudfront_enabled ? 1 : 0
  bucket = aws_s3_bucket.site.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.site.arn}/*"
      Condition = {
        StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.site[0].arn }
      }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.site]
}

# --- Certificate -----------------------------------------------------------------

resource "aws_acm_certificate" "site" {
  provider          = aws.us_east_1
  domain_name       = local.app_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for o in aws_acm_certificate.site.domain_validation_options : o.domain_name => o
  }

  zone_id = aws_route53_zone.site.zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  records = [each.value.resource_record_value]
  ttl     = 300
}

# Waits until ACM has seen the DNS record and issued the certificate, so the
# distribution below is never created against a certificate still pending.
resource "aws_acm_certificate_validation" "site" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.site.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# --- Distribution ----------------------------------------------------------------

resource "aws_cloudfront_distribution" "site" {
  count = var.cloudfront_enabled ? 1 : 0

  enabled             = true
  is_ipv6_enabled     = true
  aliases             = [local.app_domain]
  default_root_object = "index.html"
  comment             = "chess-cloud web"

  # Includes Asia (Singapore) without paying for South America and Oceania's
  # pricier edges. The audience is mostly here; nothing else changes.
  price_class = "PriceClass_200"

  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    target_origin_id       = "s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    # AWS managed "CachingOptimized". How long each file lives is set per
    # object at upload: hashed assets forever, index.html never.
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  # Client-side routes (/player/chesscom/erik) are not files. Without this,
  # opening or refreshing a deep link returns S3's error rather than the app.
  # A private bucket answers a missing key with 403, not 404 - both are mapped.
  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }

  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.site.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# --- DNS -------------------------------------------------------------------------

resource "aws_route53_record" "site" {
  for_each = var.cloudfront_enabled ? toset(["A", "AAAA"]) : toset([])

  zone_id = aws_route53_zone.site.zone_id
  name    = local.app_domain
  type    = each.value

  alias {
    name                   = aws_cloudfront_distribution.site[0].domain_name
    zone_id                = aws_cloudfront_distribution.site[0].hosted_zone_id
    evaluate_target_health = false
  }
}

# While CloudFront is off. GitHub serves the app and issues its certificate
# once this resolves to it.
resource "aws_route53_record" "pages" {
  count = var.cloudfront_enabled ? 0 : 1

  zone_id = aws_route53_zone.site.zone_id
  name    = local.app_domain
  type    = "CNAME"
  ttl     = 300
  records = ["${var.github_owner}.github.io"]
}

resource "aws_route53_record" "pages_verification" {
  count = var.github_pages_verification == "" ? 0 : 1

  zone_id = aws_route53_zone.site.zone_id
  name    = "_github-pages-challenge-${var.github_owner}.${var.domain_name}"
  type    = "TXT"
  ttl     = 300
  records = [var.github_pages_verification]
}

# --- Outputs ---------------------------------------------------------------------

# The four Porkbun points at.
output "name_servers" {
  value = aws_route53_zone.site.name_servers
}

output "zone_id" {
  value = aws_route53_zone.site.zone_id
}

output "bucket" {
  value = aws_s3_bucket.site.bucket
}

output "distribution_id" {
  value = one(aws_cloudfront_distribution.site[*].id)
}

output "url" {
  value = "https://${local.app_domain}"
}
