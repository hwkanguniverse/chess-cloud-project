#!/usr/bin/env bash
# Checks the live AWS account against the constraints in the aws-cert-plan skill.
# These are the ones that cost real money or invalidate the architecture story.
# Run after every apply. Exit 1 means the build has drifted from the roadmap.

set -uo pipefail
REGION="ap-southeast-1"
FAIL=0

# Runnable from any directory, including a terraform/ subdir mid-workflow.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

flag() { echo "  DRIFT: $1"; FAIL=1; }
ok()   { echo "  ok: $1"; }

echo "Checking against aws-cert-plan constraints ($REGION)"
echo

# "No NAT Gateway" - ~$32/month, the single biggest cost trap in the plan.
echo "NAT Gateway (skill: none, ~\$32/mo):"
NAT=$(aws ec2 describe-nat-gateways --region "$REGION" \
  --filter Name=state,Values=available,pending \
  --query 'length(NatGateways)' --output text 2>/dev/null || echo "?")
[ "$NAT" = "0" ] && ok "none" || flag "$NAT NAT Gateway(s) exist"

# "No ALB" - ~$17/month. Nothing routes to a queue consumer.
echo "Load balancers (skill: none, ~\$17/mo):"
LB=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --query 'length(LoadBalancers)' --output text 2>/dev/null || echo "?")
[ "$LB" = "0" ] && ok "none" || flag "$LB load balancer(s) exist"

# "No RDS" - DynamoDB covers both access patterns.
echo "RDS instances (skill: none, DynamoDB covers it):"
RDS=$(aws rds describe-db-instances --region "$REGION" \
  --query 'length(DBInstances)' --output text 2>/dev/null || echo "?")
[ "$RDS" = "0" ] && ok "none" || flag "$RDS RDS instance(s) exist"

# "Scale to zero" - the difference between ~$0 and ~$44/month of idle Fargate.
echo "Fargate scale-to-zero (skill: min 0 tasks):"
CLUSTERS=$(aws ecs list-clusters --region "$REGION" --query 'clusterArns' --output text 2>/dev/null)
if [ -z "$CLUSTERS" ]; then
  ok "no clusters yet"
else
  for C in $CLUSTERS; do
    SVCS=$(aws ecs list-services --cluster "$C" --region "$REGION" --query 'serviceArns' --output text 2>/dev/null)
    [ -z "$SVCS" ] && continue
    for S in $SVCS; do
      RES="service/$(basename "$C")/$(basename "$S")"
      MIN=$(aws application-autoscaling describe-scalable-targets \
        --service-namespace ecs --region "$REGION" \
        --resource-ids "$RES" \
        --query 'ScalableTargets[0].MinCapacity' --output text 2>/dev/null)
      case "$MIN" in
        0)         ok "$(basename "$S") scales to zero" ;;
        None|"")   flag "$(basename "$S") has no autoscaling target - idle Fargate is ~\$44/mo" ;;
        *)         flag "$(basename "$S") min capacity is $MIN, not 0" ;;
      esac
    done
  done
fi

# Budget must be MONTHLY and must warn BEFORE the money is gone, not after.
BUDGET="chess-cloud-monthly"
ACCT=$(aws sts get-caller-identity --query Account --output text)

echo "Budget period (skill: \$5/month):"
UNIT=$(aws budgets describe-budget --account-id "$ACCT" --budget-name "$BUDGET" \
  --query 'Budget.TimeUnit' --output text 2>/dev/null || echo "MISSING")
[ "$UNIT" = "MONTHLY" ] && ok "monthly" || flag "budget is '$UNIT', not MONTHLY - an annual \$5 cap is spent by one ordinary month"

echo "Budget forecast alert (warns before the money is gone):"
FC=$(aws budgets describe-notifications-for-budget \
  --account-id "$ACCT" --budget-name "$BUDGET" \
  --query "length(Notifications[?NotificationType=='FORECASTED'])" --output text 2>/dev/null || echo 0)
[ "$FC" != "0" ] && ok "forecast alert set" || flag "no FORECASTED alert - you learn about overspend after the fact"

# The DLQ must exist and be wired up. A queue whose redrive policy is missing
# looks identical to a working one until a poison message arrives.
echo "SQS dead letter queue:"
QURL=$(aws sqs get-queue-url --queue-name chess-cloud-analysis --region "$REGION" \
  --query QueueUrl --output text 2>/dev/null)
if [ -z "$QURL" ] || [ "$QURL" = "None" ]; then
  ok "queue not created yet"
else
  RD=$(aws sqs get-queue-attributes --queue-url "$QURL" --region "$REGION" \
    --attribute-names RedrivePolicy --query 'Attributes.RedrivePolicy' --output text 2>/dev/null)
  case "$RD" in
    *deadLetterTargetArn*) ok "redrive policy set" ;;
    *)                     flag "main queue has no redrive policy - failures would retry forever" ;;
  esac

  # Messages here mean games failed every retry. Not drift, but nothing else
  # surfaces it and an unnoticed DLQ is the same as no DLQ.
  #
  # This polls rather than reading ApproximateNumberOfMessages, which lags -
  # observed reporting 0 for a DLQ that held a message, and 1 for one already
  # empty. A check that reports "all clear" when it is not is worse than a
  # slow one. Costs ~5s when empty.
  #
  # visibility-timeout 0 keeps anything found immediately available to the real
  # worker, and nothing is ever deleted - this only looks.
  DURL=$(aws sqs get-queue-url --queue-name chess-cloud-analysis-dlq --region "$REGION" \
    --query QueueUrl --output text 2>/dev/null)
  if [ -n "$DURL" ] && [ "$DURL" != "None" ]; then
    BODY=$(aws sqs receive-message --queue-url "$DURL" --region "$REGION" \
      --wait-time-seconds 5 --visibility-timeout 0 \
      --query 'Messages[0].Body' --output text 2>/dev/null)
    if [ -z "$BODY" ] || [ "$BODY" = "None" ]; then
      ok "dlq empty"
    else
      echo "  NOTE: message(s) in the DLQ - these failed every retry: $BODY"
    fi
  fi
fi

echo
[ "$FAIL" = "0" ] && echo "No drift." || echo "Drift found - reconcile with the skill or log it in CLAUDE.md."
exit $FAIL
