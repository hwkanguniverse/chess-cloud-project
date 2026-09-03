# Network layer: the VPC the Fargate workers run in.
#
# Until Phase 6 both services ran in the account's **default** VPC. That
# worked and cost nothing, so the reason to replace it is not security -
# exposure is identical either way, and is already zero. The reason is that
# the default VPC is *undeclared state*: it is not in Terraform, so
# check-drift.sh can assert nothing about it, its subnets auto-assign public
# IPs by inheritance rather than by choice, and it is the one piece of
# infrastructure here that cannot be rebuilt from code. That contradicts the
# project's own no-console-clicking rule, and the fix costs $0.
#
# **Subnets are public, deliberately.** See the decision log in CLAUDE.md. The
# short version: private subnets defend against something reaching the tasks,
# which already cannot happen - nothing routes TO a queue consumer and the
# security group has zero inbound rules. What they would actually buy is
# insurance against a *future* misconfigured SG, and there is no cheap way to
# buy it: Fargate cannot start a task without reaching ECR and CloudWatch
# Logs, neither of which has a free gateway endpoint, so private means ~$28/mo
# of interface endpoints or a ~$32/mo NAT Gateway. Against a ~$2 budget that
# is 14-16x the entire project to remove an exposure that is not there.
#
# Cost posture:
#   - No NAT Gateway (~$32/mo). Public subnet + IGW gives outbound for free.
#   - No ALB (~$17/mo). Nothing routes to a queue consumer.
#   - Gateway endpoints for DynamoDB and S3 are **free** and are taken anyway:
#     they change the traffic path rather than the diagram.
#   - Total recurring cost of this root: **$0**.

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
    key          = "network/terraform.tfstate"
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

variable "vpc_cidr" {
  description = <<-EOT
    The VPC's address range.

    10.0.0.0/16 rather than the default VPC's 172.31.0.0/16, chosen to be
    obviously *not* the default: a CIDR that does not collide makes it
    unambiguous which network a task is in when reading an ENI or a flow log.

    /16 is far more address space than this workload needs - 8 Fargate tasks
    at peak - but a VPC CIDR cannot be shrunk later and unused private
    addresses cost nothing. Sizing down would be optimising a free resource.
  EOT
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = <<-EOT
    How many availability zones to place subnets in.

    Two, not one: ECS places a task where there is capacity, and the evaluator
    runs on Fargate **Spot**, which is exactly the capacity that runs out. One
    AZ makes a Spot shortage in that AZ a hard stop; two gives ECS somewhere
    else to go, and costs nothing because subnets are free and there is no NAT
    or ALB to duplicate per AZ.

    Two rather than the default VPC's three: a third AZ adds no availability
    this workload can use and is another range to plan.
  EOT
  type        = number
  default     = 2
}

# --- The VPC ---------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  # Both on: ECS tasks and VPC endpoints resolve AWS service names, and the
  # interface-endpoint path (should this ever go private) depends on private
  # DNS, which silently does nothing without these two.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "chess-cloud"
  }
}

# --- Public subnets --------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"
}

# One /20 per AZ out of the /16, carved by index. cidrsubnet() rather than
# hardcoded ranges so adding an AZ is a variable change, not an arithmetic
# exercise - and so the ranges cannot silently overlap.
resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  # Explicit, and this is the point of the whole root. The default VPC does
  # exactly this too - but by inheritance, as a property nobody in this
  # project chose. Here it is a declared decision: the task needs a routable
  # address to reach Chess.com and the AWS APIs, because there is no NAT to
  # borrow one from.
  map_public_ip_on_launch = true

  tags = {
    Name = "chess-cloud-public-${data.aws_availability_zones.available.names[count.index]}"
  }
}

# --- Internet gateway and routing ------------------------------------------

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "chess-cloud"
  }
}

# One route table shared by both subnets. They have identical routing - a
# default route to the IGW - so a table each would be two copies of one fact.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "chess-cloud-public"
  }
}

# What makes these subnets public: a default route to the internet gateway.
# "Public subnet" is not a subnet attribute, it is this route - the single
# most common misconception in the VPC material.
resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  count = var.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# --- Gateway endpoints -----------------------------------------------------
#
# Free, unlike interface endpoints. They install a prefix-list route in the
# route table, so traffic to these two services leaves via the AWS network
# rather than the internet gateway - a real change to the path, not a label.
#
# Taken even though the subnets are public, because $0 improvements do not
# have to argue for themselves against a $2 budget.

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.public.id]

  tags = {
    Name = "chess-cloud-dynamodb"
  }
}

# S3 has no bucket in this project, which makes this look like decoration. It
# is not: **ECR stores image layers in S3**, so every task start pulls the
# worker image through this endpoint. It is on the task-start path, and it is
# the one to suspect first if tasks stop being able to start.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.public.id]

  tags = {
    Name = "chess-cloud-s3"
  }
}

# --- Security group --------------------------------------------------------
#
# **One group for both services, and that is a decision rather than laziness.**
#
# The obvious least-privilege move is a group each: ingestion talks to
# Chess.com, the evaluator makes *zero* upstream requests, so why let the
# evaluator reach the internet at all? The answer is that the rule you would
# write is identical either way. Restricting egress means naming what the task
# may reach, and the evaluator must still reach ECR, CloudWatch Logs and SQS -
# none of which has a free gateway endpoint, all of which sit on large and
# changing AWS ranges. In practice that is 443 to 0.0.0.0/0: the same rule,
# under a name claiming it is tighter.
#
# Two identical rule sets with a misleading name is worse than one honest
# group - it is a control that looks like it enforces something and does not,
# which is the exact pattern Phase E kept finding behind healthy status.
#
# Splitting them becomes real only with interface endpoints for ECR, Logs and
# SQS (~$28/mo), which is the option already rejected in the decision log for
# 14x the project budget. Revisit the split if those ever exist; until then
# one group states the truth.
#
# Named for what it holds - both task families - rather than "worker", which
# read as one service and was shared by two.
resource "aws_security_group" "tasks" {
  name        = "chess-cloud-tasks"
  description = "Fargate tasks - egress only, nothing routes in"
  vpc_id      = aws_vpc.main.id

  # **No ingress blocks at all, and this is the control doing the real work.**
  # Both services are queue consumers: they poll SQS and are never a
  # destination. With no inbound rule the public subnet is irrelevant to
  # exposure - there is no listener and no path in. This absence is what made
  # private subnets unnecessary, so it is the line to defend in review.
  egress {
    description = "HTTPS out: Chess.com for ingestion, AWS APIs for both"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "chess-cloud-tasks"
  }
}

# --- Outputs ---------------------------------------------------------------

output "vpc_id" {
  description = "For the worker's security groups."
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  value = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "Where the ECS services place tasks."
  value       = aws_subnet.public[*].id
}

output "route_table_id" {
  value = aws_route_table.public.id
}

output "tasks_security_group_id" {
  description = "The one security group both Fargate services use."
  value       = aws_security_group.tasks.id
}
