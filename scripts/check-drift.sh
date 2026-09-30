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

      # Max capacity is the upstream guard, and the only one here whose
      # failure cannot be undone with money. Chess.com's rule is phrased per
      # caller, so two tasks on different players are still two overlapping
      # requests of ours; one task is the only configuration known to comply,
      # and the cost of getting it wrong is an IP ban rather than a bill.
      # The reasoning lives in terraform/worker/main.tf - this is the check
      # that would notice it being raised by hand in the console.
      MAX=$(aws application-autoscaling describe-scalable-targets \
        --service-namespace ecs --region "$REGION" \
        --resource-ids "$RES" \
        --query 'ScalableTargets[0].MaxCapacity' --output text 2>/dev/null)
      # Only the ingestion worker. The evaluator reads stored PGNs and makes
      # no upstream requests at all, so serialisation buys nothing there and
      # its ceiling is a cost decision rather than a safety one.
      if [ "$(basename "$S")" = "worker" ]; then
        case "$MAX" in
          1)         ok "$(basename "$S") pinned to one task - ingestion stays serialised" ;;
          None|"")   : ;; # already reported by the MinCapacity check above
          *)         flag "$(basename "$S") max capacity is $MAX, not 1 - parallel requests risk an IP ban" ;;
        esac
      else
        ok "$(basename "$S") max capacity $MAX - no upstream calls, so not pinned"
      fi
    done
  done
fi

# --- Phase 6: the network ---------------------------------------------------
#
# The justification for building a VPC at all was that the default one is
# undeclared state nothing can assert on. Building it and then not asserting
# anything would move that gap rather than close it, so these checks are the
# point of the phase rather than an addition to it.

# The security group's *absence* of ingress rules is the control that made
# private subnets unnecessary - nothing routes to a queue consumer, so with no
# inbound rule a public subnet is irrelevant to exposure. That argument holds
# only while the rule count stays zero, and a single console click would end
# it silently. This is the one check here that guards a security property
# rather than a cost.
echo "Task security group (no inbound - what makes public subnets safe):"
SG=$(aws ec2 describe-security-groups --region "$REGION"   --filters Name=group-name,Values=chess-cloud-tasks   --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
if [ -z "$SG" ] || [ "$SG" = "None" ]; then
  flag "chess-cloud-tasks security group is missing"
else
  INGRESS=$(aws ec2 describe-security-groups --region "$REGION" --group-ids "$SG"     --query 'length(SecurityGroups[0].IpPermissions)' --output text 2>/dev/null)
  if [ "$INGRESS" = "0" ]; then
    ok "no inbound rules"
  else
    flag "$INGRESS inbound rule(s) - the no-ingress argument for public subnets no longer holds"
  fi
fi

# Both services must be in the purpose-built VPC. The failure mode is not
# hypothetical: a service reverting to the default VPC's subnets would keep
# working perfectly, since that is where it ran until Phase 6 - so nothing
# would surface it except this check.
echo "Fargate tasks in the purpose-built VPC (not the default):"
VPC=$(aws ec2 describe-vpcs --region "$REGION"   --filters Name=tag:Name,Values=chess-cloud   --query 'Vpcs[0].VpcId' --output text 2>/dev/null)
if [ -z "$VPC" ] || [ "$VPC" = "None" ]; then
  flag "the chess-cloud VPC is missing"
else
  WANT=$(aws ec2 describe-subnets --region "$REGION"     --filters Name=vpc-id,Values="$VPC"     --query 'sort_by(Subnets,&SubnetId)[].SubnetId' --output text 2>/dev/null)
  for S in worker evaluator; do
    GOT=$(aws ecs describe-services --cluster chess-cloud --services "$S" --region "$REGION"       --query 'sort_by(services[0].networkConfiguration.awsvpcConfiguration.subnets,&@)'       --output text 2>/dev/null)
    if [ -z "$GOT" ] || [ "$GOT" = "None" ]; then
      ok "$S not deployed yet"
    elif [ "$GOT" = "$WANT" ]; then
      ok "$S in $VPC"
    else
      flag "$S is not in the chess-cloud VPC's subnets - check it has not reverted to the default VPC"
    fi
  done
fi

# Free, and on the task-start path. The DynamoDB endpoint keeps table traffic
# off the public internet; the S3 one is what ECR pulls image layers through,
# so losing it is a task-start failure rather than a cosmetic one. Both are
# $0, which means nothing pressures them to exist - the usual reason a free
# thing quietly disappears.
echo "Gateway endpoints (free, and S3 is on the ECR image-pull path):"
if [ -n "$VPC" ] && [ "$VPC" != "None" ]; then
  for SVC in dynamodb s3; do
    N=$(aws ec2 describe-vpc-endpoints --region "$REGION"       --filters Name=vpc-id,Values="$VPC" Name=service-name,Values="com.amazonaws.$REGION.$SVC"       --query 'length(VpcEndpoints[?State==`available`])' --output text 2>/dev/null)
    if [ "$N" = "1" ]; then
      ok "$SVC endpoint present"
    else
      flag "$SVC gateway endpoint missing - it is free, so there is no reason for it to be gone"
    fi
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

# The alert path, checked link by link along the way an alert travels,
# because each link fails silently - a missing alarm, actions disabled (left
# over from a drill), an action pointing at the wrong topic, or a subscription
# never confirmed all leave the alarm free to fire into nothing.
alert_path() {
  local ALARM="$1" WHY="$2" ENABLED TOPIC CONFIRMED
  read -r ENABLED TOPIC <<<"$(aws cloudwatch describe-alarms --alarm-names "$ALARM" \
    --region "$REGION" --query 'MetricAlarms[0].[ActionsEnabled,AlarmActions[0]]' \
    --output text 2>/dev/null)"
  if [ -z "$ENABLED" ] || [ "$ENABLED" = "None" ]; then
    flag "no alarm $ALARM - $WHY"
    return
  fi
  [ "$ENABLED" = "True" ] && ok "alarm exists, actions enabled" \
    || flag "$ALARM has actions disabled - it can go to ALARM and tell no one"
  case "$TOPIC" in
    arn:aws:sns:*) ;;
    *) flag "$ALARM has no SNS action - it notifies no one"; return ;;
  esac
  CONFIRMED=$(aws sns list-subscriptions-by-topic --topic-arn "$TOPIC" --region "$REGION" \
    --query "length(Subscriptions[?SubscriptionArn!='PendingConfirmation'])" \
    --output text 2>/dev/null || echo 0)
  [ "${CONFIRMED:-0}" != "0" ] && [ "$CONFIRMED" != "None" ] \
    && ok "notifies ${TOPIC##*:}, $CONFIRMED confirmed subscription(s)" \
    || flag "$ALARM notifies ${TOPIC##*:}, which has no confirmed subscription - alerts are dropped"
}

# The DLQ must exist and be wired up. A queue whose redrive policy is missing
# looks identical to a working one until a poison message arrives.
#
# Both queues, each with its own DLQ. Until Phase 4 this checked only the
# ingestion one - the evaluation DLQ had never been looked at by anything.
for Q in chess-cloud-analysis chess-cloud-analysis-eval; do
  echo "SQS dead letter queue ($Q):"
  QURL=$(aws sqs get-queue-url --queue-name "$Q" --region "$REGION" \
    --query QueueUrl --output text 2>/dev/null)
  if [ -z "$QURL" ] || [ "$QURL" = "None" ]; then
    ok "queue not created yet"
    continue
  fi
  RD=$(aws sqs get-queue-attributes --queue-url "$QURL" --region "$REGION" \
    --attribute-names RedrivePolicy --query 'Attributes.RedrivePolicy' --output text 2>/dev/null)
  case "$RD" in
    *deadLetterTargetArn*) ok "redrive policy set" ;;
    *)                     flag "$Q has no redrive policy - failures would retry forever" ;;
  esac

  # Messages here mean work failed every retry. Not drift - the alarm below is
  # what reports it - but printed so a run of this script shows it too.
  #
  # This polls rather than reading ApproximateNumberOfMessages, which lags -
  # observed reporting 0 for a DLQ that held a message, and 1 for one already
  # empty. A check that reports "all clear" when it is not is worse than a
  # slow one. Costs ~5s when empty.
  #
  # visibility-timeout 0 leaves anything found where it was, and nothing is
  # ever deleted - this only looks.
  DLQ="$Q-dlq"
  DURL=$(aws sqs get-queue-url --queue-name "$DLQ" --region "$REGION" \
    --query QueueUrl --output text 2>/dev/null)
  if [ -n "$DURL" ] && [ "$DURL" != "None" ]; then
    BODY=$(aws sqs receive-message --queue-url "$DURL" --region "$REGION" \
      --wait-time-seconds 5 --visibility-timeout 0 \
      --query 'Messages[0].Body' --output text 2>/dev/null)
    if [ -z "$BODY" ] || [ "$BODY" = "None" ]; then
      ok "dlq empty"
    else
      echo "  NOTE: message(s) in $DLQ - these failed every retry: $BODY"
    fi
  fi

  alert_path "$DLQ-not-empty" "a dead message would sit unnoticed until it expires"
done

# Phase 4's other alarm. Until Phase 5 this was claimed as drift-checked and
# was not - found while extending this script.
echo "Lambda errors alarm (any function erroring or timing out):"
alert_path chess-cloud-lambda-errors "a crashing or timing-out Lambda would tell no one"

# The CI roles' trust policies are the control on who can deploy: the apply
# role is AdministratorAccess by decision, so its trust is the account's front
# door with no MFA behind it. The failure worth catching is a *loosening* -
# a StringLike, a wildcard, a second subject - because every workflow would
# keep working perfectly, the failure that looks like success. So this does
# not ask "can CI still deploy" (the pipeline answers that) but "can anything
# else": exact operator, exact subject, one statement, and no other role
# trusting GitHub at all.
echo "CI trust (who can assume the deploy roles):"
GH_SUB="repo:hwkanguniverse@8513534/chess-cloud-project@1332943637"
GH_PROVIDER="arn:aws:iam::$ACCT:oidc-provider/token.actions.githubusercontent.com"
AUD=$(aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$GH_PROVIDER" \
  --query 'ClientIDList' --output text 2>/dev/null)
[ "$AUD" = "sts.amazonaws.com" ] && ok "GitHub OIDC provider, audience sts only" \
  || flag "GitHub OIDC provider missing or audience is '$AUD'"

# role : subject it must trust : the one managed policy it may hold
for PAIR in "chess-cloud-ci-plan:$GH_SUB:pull_request:ReadOnlyAccess" \
            "chess-cloud-ci-apply:$GH_SUB:ref:refs/heads/main:AdministratorAccess"; do
  ROLE=${PAIR%%:*}; REST=${PAIR#*:}; POLICY=${REST##*:}; WANT=${REST%:*}
  DOC=Role.AssumeRolePolicyDocument
  read -r N EFFECT ACTION FED OPS KEYS <<<"$(aws iam get-role --role-name "$ROLE" --output text \
    --query "[length($DOC.Statement), $DOC.Statement[0].Effect, $DOC.Statement[0].Action,
              $DOC.Statement[0].Principal.Federated,
              join(',', keys($DOC.Statement[0].Condition)),
              join(',', sort(keys($DOC.Statement[0].Condition.StringEquals)))]" 2>/dev/null)"
  SUB=$(aws iam get-role --role-name "$ROLE" --output text \
    --query "$DOC.Statement[0].Condition.StringEquals.\"token.actions.githubusercontent.com:sub\"" 2>/dev/null)
  if [ -z "$N" ]; then flag "$ROLE is missing"; continue; fi
  if [ "$N" = 1 ] && [ "$EFFECT" = Allow ] && [ "$ACTION" = sts:AssumeRoleWithWebIdentity ] \
    && [ "$FED" = "$GH_PROVIDER" ] && [ "$OPS" = StringEquals ] \
    && [ "$KEYS" = "token.actions.githubusercontent.com:aud,token.actions.githubusercontent.com:sub" ] \
    && [ "$SUB" = "$WANT" ]; then
    ok "$ROLE trusts exactly ${WANT#"$GH_SUB":}"
  else
    flag "$ROLE trust is not exactly StringEquals on '$WANT' (statements=$N operators=$OPS sub=$SUB)"
  fi

  GOT=$(aws iam list-attached-role-policies --role-name "$ROLE" --output text \
    --query 'join(`,`, AttachedPolicies[].PolicyName)' 2>/dev/null)
  INLINE=$(aws iam list-role-policies --role-name "$ROLE" --output text \
    --query 'length(PolicyNames)' 2>/dev/null)
  [ "$GOT" = "$POLICY" ] && [ "$INLINE" = 0 ] && ok "$ROLE has $POLICY only" \
    || flag "$ROLE policies are '$GOT' plus $INLINE inline, expected $POLICY only"
done

OTHERS=$(aws iam list-roles --output text --query \
  "Roles[?contains(to_string(AssumeRolePolicyDocument), 'token.actions.githubusercontent.com')
         && RoleName!='chess-cloud-ci-plan' && RoleName!='chess-cloud-ci-apply'].RoleName" 2>/dev/null)
[ -z "$OTHERS" ] && ok "no other role trusts GitHub" \
  || flag "other role(s) trust GitHub's OIDC provider: $OTHERS"

echo
[ "$FAIL" = "0" ] && echo "No drift." || echo "Drift found - reconcile with the skill or log it in CLAUDE.md."
exit $FAIL
