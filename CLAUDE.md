# Phase 4 — Observability

**Goal:** be able to answer "what happened?" without guessing. Six phases in, the way to find out why something failed is to read raw `print()` output stream by stream and correlate by timestamp. That worked because there is one user who knows the system. It is the thing that stops working first when there is not.

**This phase maps to SOA**, and it is the one the skill singles out: *"this is where student projects are usually empty"*. Every prior phase produced something visible — a queue draining, a chart, a network. This one produces the ability to *see*, which is harder to demo and easier to skip.

**The temptation here is to instrument everything and alarm on nothing that matters.** CloudWatch will happily bill for custom metrics, dashboards and X-Ray traces on a workload that runs a few minutes a day. The rule below decides what gets built: name the question the telemetry answers, and who asks it.

Previous phases: [PHASE-1.md](PHASE-1.md), [PHASE-2.md](PHASE-2.md), [PHASE-3.md](PHASE-3.md), [PHASE-F.md](PHASE-F.md), [PHASE-E.md](PHASE-E.md), [PHASE-6.md](PHASE-6.md). Read them for decisions already made, and do not redo them.

**Two things are owed from earlier phases and are not this phase's work:**
- **Phase F's hosting is still blocked on choosing a domain** — CORS, the browser drills and the public launch all wait behind it. Still the longest-standing open item in the project.
- **Phase E's per-player claim is deployed but never drilled live.** Every stored player is fully evaluated, so nothing reaches the claim. A third player would exercise it.

Account: `961868442307` · Region: `ap-southeast-1` · IAM user: `terraform-admin` (MFA enabled)

---

## How we work on this

Unchanged since Phase 1, and still the point of the exercise. This project is a learning exercise; the deliverable is understanding, not a finished stack — a working stack I cannot explain is a failed phase.

**Claude writes the code. I make the decisions, after I understand them.**

- **Explain first, then write.** Before adding a service: what problem it solves in *this* app, what breaks without it, what it costs. Then I decide, then you write it.
- **Ask, don't assume.** Any choice with a real trade-off — service selection, retry policy, storage layout, what counts as done — is mine. Present the options and what each costs, then wait.
- **Name the failure mode** a service exists to handle here. If the honest answer is "real systems use it", it gets cut — that rule cut S3 in Phase 3, the automated spending stop in Phase F, account verification in Phase E, and private subnets in Phase 6.
- **Tick items off in this file as they are completed.** A stale checklist is worse than none.
- **Record decisions in the log below** — choice, alternative, reason. The reasoning is what fades.
- **Say when I am wrong, and why.** Agreeing with a bad call to be pleasant wastes the exercise.
- **Keep this file high level.** Purpose and decisions. Implementation detail lives in the code.

## Staying faithful to the roadmap

The `aws-cert-plan` skill is the source of truth for architecture and cost decisions. This file is a working checklist derived from it — **it does not override it.** Where they disagree, the skill wins and this file gets fixed.

- **Do not restate the skill's reasoning here** — reference it.
- **Re-read the skill at the start of each phase**, and before any decision it already covers. Do not work from memory of it.
- **Any deviation goes in the Deviations table below, with a reason**, or it does not happen.
- **If a constraint turns out to be wrong**, that is a finding — say so, and update the *skill*, not just this file.
- **Before starting the next phase, re-read the skill and update it to match what this project actually is.** Not a changelog — it should simply describe the project accurately as it now stands.

*Access note: the skill is not readable from the CLI. It is exported as `aws-cert-plan.skill` (a zip containing `SKILL.md`) in `~/Downloads` and unpacked. **Updated 3 Sep 2026** to describe the project as of the end of Phase 6 — the stale "ECS + ALB + RDS, apply/screenshot/destroy" row is replaced by what was actually built, the private-subnet decision and its costing are recorded, and the apply/destroy discipline is narrowed to what bills hourly while idle.*

Run `bash scripts/check-drift.sh` after every apply.

---

## Where observability is today

Stated first, because this phase is a retrofit and the gaps are specific rather than general.

- **19 `print()` calls across the app.** No `logging`, no levels, no structure. They are genuinely useful lines — `fetching … (conditional)`, `done GAME#…: acpl=163 blunders=9` — but they are prose, so nothing can filter, count or alarm on them.
- **No request IDs anywhere.** A player's submit fans out to ~200 messages across two services and several minutes. Nothing ties those log lines back to the request that caused them.
- **Every alarm is a scaling alarm.** Four exist — `queue-has-work`, `queue-empty`, and the evaluator's pair. All of them exist to *move task counts*. **Not one of them tells you something is wrong.**
- **The DLQ has no alarm.** `check-drift.sh` polls it, but only when run by hand. A message can sit there indefinitely.
- **Log retention is 14 days** on every project group, which is deliberate and fine.
- **There is a stray `/aws/lambda/my-s3-function` log group with no retention set** — not from this project, not in Terraform. A leftover from console experimentation, and a small live example of the undeclared state Phase 6 was about.

**The honest question this phase has to answer:** what would I actually want to know, and when? Candidate answers to test rather than assume:

- Something failed and nobody is watching — the DLQ case, and the only one with a real user-visible cost.
- A run is slower or more expensive than expected, and I want to know which stage.
- A specific user's specific request went wrong and I need to follow it end to end.

Instrumentation that answers none of those is decoration.

---

## To decide before building

Each of these has a real trade-off and a real price.

- [ ] **Structured JSON logs — worth the rewrite, or not?** The skill lists them. They make lines filterable and metric-filterable, which is what everything else in this phase depends on. The cost is touching all 19 call sites and losing human-readable output when tailing. **Options: JSON everywhere; JSON in the workers only; keep prose and parse it with metric filters.**
- [ ] **Request IDs: how far do they need to travel?** A request ID is cheap inside one Lambda and real work across an SQS fan-out — it has to ride in the message body and be logged by the worker. Worth deciding whether the goal is per-Lambda correlation or genuine end-to-end tracing.
- [ ] **Which alarm actually gets built first?** The skill's requirement is "an alarm that demonstrably fires". The DLQ alarm is the obvious candidate: it is the only current failure mode with no human in the loop. **Cost: an SNS topic and email, both ~$0.**
- [ ] **X-Ray: yes or no?** The skill lists it. It costs per trace beyond the free tier, and this project's slow path is a *queue wait*, not a call graph — the thing X-Ray is best at showing is the thing Phase 3 already measured by hand. **Name the question it answers that CloudWatch cannot**, or cut it.
- [ ] **Dashboard: one, or none?** A CloudWatch dashboard is $3/month beyond the first three — real money at this budget. Decide whether the audience is me during a drill (logs are better) or a portfolio screenshot (a dashboard is better).

## To build

Ordered so each piece is verifiable before the next depends on it.

- [ ] **Structured logging**, in whatever form is decided above, with the existing useful lines preserved rather than replaced.
- [ ] **Request IDs threaded through** the paths that fan out, so one submit can be followed across services.
- [ ] **A metric filter** turning a log pattern into a number — the SOA-shaped skill this phase is for.
- [ ] **At least one alarm that demonstrably fires**, wired to something that reaches me. The skill's wording is deliberate: an alarm nobody has seen fire is an assertion, not a control.
- [ ] **`check-drift.sh` extended** to assert whatever this phase decides is load-bearing — most likely the DLQ alarm's existence, since an unnoticed DLQ is the failure this phase is for.
- [ ] **Delete the stray `my-s3-function` log group**, or adopt it into Terraform. It is undeclared state, and Phase 6's whole argument was that undeclared state should not exist.

## What must not change

Carried forward because the temptation to revisit them does not go away.

- [ ] **Ingestion stays pinned at `max_capacity = 1`.** The Chess.com constraint is unchanged, and it is still the one risk money cannot undo.
- [ ] **Scale-to-zero stays.** `MinCapacity == 0` per service, drift-checked. Eight idle evaluators are ~$108/month against a ~$2 budget.
- [ ] **No ALB, no NAT, no RDS.** Phase 6 priced all three and rejected them. Observability is not a reason to revisit any of it.
- [ ] **Both services stay in the purpose-built VPC**, with the task security group holding zero inbound rules. Drift-checked as of Phase 6.

## Failure paths to drill

Same standard as every prior phase: watched live, not asserted. Phase E recorded four bugs that hid behind healthy status, and Phase 6 found that the most dangerous failures are the ones that look like success.

- [ ] **The alarm fires for real** → not simulated with `set-alarm-state`. Put a message in the DLQ and watch the notification arrive.
- [ ] **A request is followed end to end** → pick one submit, find every line it produced across both services, and confirm the correlation actually works.
- [ ] **The logs answer a question they could not answer before** → the test of whether this phase did anything.

## Cost controls

- [ ] **Know what the telemetry costs before building it.** CloudWatch bills custom metrics (~$0.30/metric/month), dashboards (~$3/month past three), and X-Ray per trace. Logs ingestion is ~$0.50/GB. None of it is free at scale, and this project's whole budget is ~$2.
- [ ] **Re-run `scripts/check-drift.sh` after each apply.**
- [ ] **Workers back to zero after every drill.**

---

## Deviations from the roadmap

Earlier phases' deviations are in their own files and still stand.

| Deviation | Skill says | We did | Why |
|---|---|---|---|
| *(none yet)* | | | |

## Decision log

Earlier decisions are in [PHASE-1.md](PHASE-1.md), [PHASE-2.md](PHASE-2.md), [PHASE-3.md](PHASE-3.md), [PHASE-F.md](PHASE-F.md), [PHASE-E.md](PHASE-E.md) and [PHASE-6.md](PHASE-6.md), and remain binding.

| Decision | Chosen | Rejected | Why |
|---|---|---|---|
| *(none yet)* | | | |

---

## Watch for

Carried from Phase 6 and Phase E because they are about how this project goes wrong.

- **An alarm nobody has watched fire is an assertion, not a control.** The skill's phrasing — "an alarm that demonstrably fires" — is the whole point of this phase.
- **The most dangerous failures look like success.** Phase 6's drift check exists because a service reverting to the default VPC would keep working perfectly. Ask of each new check: what would this catch that nothing else would?
- **Prove a new check fails, not just that it passes.** A check only ever seen green is untested — and in Phase 6 two apparent DRIFT results turned out to be a bug in the check itself.
- **`terraform apply` does not deploy the worker.** The Lambdas are repackaged from source; the worker ships as a container tagged `:latest`. After changing anything under `app/worker/`, build and push the image and verify the code is in it before trusting a run.
- **Deploying is a distinct test from running.** Phase 3 found three runtime-only IAM bugs, Phase E four more. Logging changes have the same property: a log line that fails to serialise fails only when that path executes.
- **Failures surface where the component lives, not where you look first.** A task that cannot start writes nothing to CloudWatch Logs — it appears in ECS service events. Phase E's execution-role bug and Phase 6's ECR drill are the same lesson twice.
- **`aws logs` needs `MSYS_NO_PATHCONV=1` in Git Bash on Windows**, and `filter-log-events` has silently returned nothing where `get-log-events` returned 622 lines. Read streams directly.
