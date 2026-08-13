# Phase 1 — Checklist

**Goal:** the full pipeline shape working end to end with a *fake* worker. API Gateway → Lambda → DynamoDB → SQS → Fargate, all in Terraform, no Stockfish anywhere.

**The rule that makes this phase work:** the worker receives a message, sleeps 10s, writes a hardcoded result. Nothing more. When something breaks you are debugging AWS *or* chess, never both at once. Resist adding the engine early — it is the single most expensive mistake available in this phase.

**Nothing is built yet.** The repo is `.gitignore`, `README.md`, and this file. Phase 1 needs almost no product code — a fake worker and two thin handlers. Real PGN parsing, Stockfish, and the dashboard all come later. Do not start writing chess logic during this phase.

Account: `961868442307` · Region: `ap-southeast-1` · IAM user: `terraform-admin` (MFA enabled)

---

## How we work on this

This project is a learning exercise. The deliverable is understanding, not a finished stack — a working pipeline I cannot explain is a failed phase.

**Claude writes the code. I make the decisions, after I understand them.**

- **Explain first, then write.** Before adding a service: what problem it solves in *this* app, what breaks without it, what it costs. Then I decide, then you write it.
- **Ask, don't assume.** Any choice with a real trade-off — service selection, key design, timeouts, networking, billing mode — is mine. Present the options and what each costs, then wait.
- **Explain the failure mode a service exists to handle** in *this* app before adding it. If the honest answer is "real systems use it," it gets cut.
- **Tick items off in this file as they are completed.** A stale checklist is worse than none.
- **Record decisions in the log below** — choice, alternative, reason. The reasoning is what fades.
- **Say when I am wrong, and why.** Agreeing with a bad call to be pleasant wastes the exercise.
- **Keep this file high level.** Purpose of each service and the decisions behind it. Implementation detail lives in the code, not here.

**Still open:** visibility timeout, scale-in cooldown.

## Staying faithful to the roadmap

The `aws-cert-plan` skill is the source of truth for architecture and cost decisions. This file is a working checklist derived from it — **it does not override it.** Where they disagree, the skill wins and this file gets fixed.

Rules that keep the two from drifting apart:

- **Do not restate the skill's reasoning here** — reference it. Duplicated rationale is what drifts; two copies of a decision means nothing catches it when one changes.
- **Re-read the skill at the start of each phase**, and before any decision it already covers. Do not work from memory of it.
- **Any deviation goes in the Deviations table below, with a reason**, or it does not happen. Silent divergence is the failure mode.
- **The skill is the constraint list, not a suggestion.** Specifically load-bearing for Phase 1: no NAT Gateway, no ALB, scale to zero, DynamoDB over RDS, Fargate over Lambda for the worker, fake worker before Stockfish, Terraform from commit one.
- **If a constraint turns out to be wrong**, that is a finding — say so, and update the *skill* on the Claude account, not just this file. The skill already carries corrections; that is the mechanism working.

Run `bash scripts/check-drift.sh` after every apply. It checks the live account against the constraints that cost real money — NAT Gateway, load balancers, RDS, Fargate scale-to-zero, budget alerting — and exits non-zero on drift. Discipline fails silently; a script does not.

### Deviations from the roadmap

| Deviation | Skill says | We did | Why |
|---|---|---|---|
| Phase 3 worker | Lambda worker | Fargate worker | Already reconciled *in* the skill — the chess adjustment makes the worker core infrastructure, not a throwaway lab. |
| _(none yet)_ | | | |

## Decision log

Fill in as decisions are made. Format: what was chosen, what was rejected, and why.

| Decision | Chosen | Rejected | Why |
|---|---|---|---|
| Region | `ap-southeast-1` | — | Matches the cost model; closest region. |
| State locking | S3 `use_lockfile` | DynamoDB lock table | Native locking since TF 1.10; lock table deprecated in 1.11. |
| DynamoDB billing | On-demand | Provisioned | Bursty traffic — idle most of the time, then 200 games at once. Provisioned would bill for capacity that sits unused, and throttle the burst if set too low. |
| Language | Python | Node/TS, Go | Fastest to write; `boto3` well documented; `python-chess` is the standard PGN library for when Stockfish arrives, so the language does not need revisiting later. |
| State bucket | `chess-cloud-tfstate-961868442307` | Random suffix; bare name | Account-ID suffix is the standard convention and guarantees global uniqueness. Discloses the account ID, which is not a credential. Bare name leaves no room for a second account or environment later. |
| Budget period | MONTHLY $5 | Keep ANNUALLY + add forecast alert | A $5/year cap is spent by one ordinary month, after which it sits permanently over and every alert becomes noise. The roadmap's guardrail is $5/month. |
| Budget thresholds | FORECASTED 80% + ACTUAL 100% | Either alone | Forecast warns early enough to act; actual confirms. Forecasts are unreliable on a new account with no history, so the backstop stays. |
| Faster tripwire | Budget + forecast only | CloudWatch billing alarm + SNS | Would duplicate Budgets and is bound by the same ~24h billing-data lag. `scripts/check-drift.sh` catches resource-level mistakes instantly and for free. |
| _(next)_ | | | |

---

## Already done — do not redo

Verified against the live account on 2026-08-13:

- [x] AWS CLI v2.36.22 authenticated as `terraform-admin`
- [x] Terraform v1.15.8 (≥1.10, so S3 native locking is available)
- [x] Default region `ap-southeast-1` — matches the cost model
- [x] MFA on `terraform-admin`
- [x] Budget `5budget` exists at $5

---

## Guardrails

**What they are for:** the expensive mistakes here bill by the hour and are silent — a NAT Gateway (~$32/mo) or an idle Fargate task (~$44/mo) does not announce itself. The budget is the thing that notices before the credits are gone and the account auto-closes.

- [x] Budget defined in Terraform — `terraform/guardrails/`, reproducible and reviewable.
- [x] **MONTHLY** $5, not annual. The original was a $5 *annual* cap running to 2087; one ordinary month would exhaust it, leaving it permanently over and every alert meaningless.
- [x] **FORECASTED > 80%** — projects the run rate and warns while there is still time to act.
- [x] **ACTUAL > 100%** — backstop that confirms the spend, since forecasts are unreliable on an account with no billing history.
- [x] Old console-managed `5budget` deleted; replacement verified live before removal so there was no unprotected window.

## S3 — remote state

**What it is for:** Terraform records what it built in a state file. Kept locally it is one laptop away from being lost, and nothing else can safely run against it. In S3 it is durable, versioned, and locked so two runs cannot corrupt it.

Do this first — set it up once and never revisit it.

- [x] Bucket name decided: `chess-cloud-tfstate-961868442307`.
- [x] Bucket created: versioned, public access blocked, encrypted, `prevent_destroy`, old versions expire after 90 days.
- [x] Backend configured with native S3 locking (`use_lockfile`), no DynamoDB lock table.
- [x] `terraform init` clean against S3 — `terraform/guardrails/` runs on the remote backend.

*Order trap, handled: the bucket cannot be created by a run that already uses it as its backend. `terraform/bootstrap/` stays on local state and creates the bucket; everything else uses S3.*

## Repo scaffolding

- [x] **Language: Python** — see decision log.
- [ ] Directory layout: Terraform separate from application code, worker separate from handlers.
- [ ] `terraform fmt` and `validate` runnable before anything is applied.

## DynamoDB — the data store

**What it is for:** holds each game's status and, later, its analysis. Chosen over a relational database because this app has exactly two fixed access patterns and no need for joins or ad-hoc queries. With fixed patterns, DynamoDB is the *better* answer, not just the cheaper one.

Settle the keys **before** the table exists. A wrong partition key means a data migration; a wrong Lambda timeout is a one-line fix.

- [ ] Confirm the two access patterns: get game by id; list a user's games newest first.
- [ ] Understand the proposed key design and why the sort key orders by timestamp — then approve or change it.
- [ ] Confirm both patterns are served without a secondary index.
- [x] **Billing: on-demand** — see decision log.
- [ ] Check worst-case analysis payload against the 400KB per-item limit, before the engine generates real eval data.
- [ ] Table live; one item written and read back.

## SQS — the queue

**What it is for:** three jobs at once. It **decouples** submit from analysis so the API can answer immediately. It **load-levels** — a 500-game upload is accepted in a second and drained at whatever rate the worker manages. And its depth is the **autoscaling signal**, which is what makes scale-to-zero possible.

The DLQ catches messages that fail repeatedly, so one bad game cannot block the queue forever.

- [ ] Queue and DLQ created together — retrofitting a DLQ after a poison message is worse.
- [ ] Decide the visibility timeout: how long a message is hidden while being worked on. Too short and a slow job gets processed twice; too long and a crashed worker's message is stuck.

## Lambda + API Gateway — the front door

**What they are for:** two small functions that run only when called and cost nothing idle. API Gateway is the HTTP front door; Lambda is the code behind it.

- **Submit** — accept the request, record it as `PENDING`, put a message on the queue, return `202` immediately with a URL to poll.
- **Status** — look up one game and return it. The client polls this. No websockets.

Neither does real work. That is the design: analysis takes 30–90 seconds, and API Gateway hard-caps a request at **29 seconds** regardless of Lambda's own timeout. Queuing is not optional here — it is what the ceiling forces.

- [ ] Both functions live behind API Gateway.
- [ ] Each has its own role, scoped to just the table and queue it touches. No wildcards.
- [ ] End to end: post a payload → `202` + id → item appears in DynamoDB → message appears in SQS.

## Fargate — the worker

**What it is for:** the analysis job that Lambda cannot do. Later it runs Stockfish — a heavy native binary, CPU-bound, on batches that blow past Lambda's 15-minute ceiling, and it benefits from keeping a warm engine process between games. This is the rare case where "why not Lambda" has a real answer.

Fargate means containers without managing servers. **In Phase 1 the worker is fake:** receive a message, sleep 10 seconds, write a hardcoded result. Get the plumbing right before the engine arrives.

- [ ] ECR repository — where the container image lives so ECS can pull it.
- [ ] Worker loop: long-poll queue → sleep → write result → mark `COMPLETE` → delete message.
- [ ] ECS cluster, task definition, service.
- [ ] Understand **task role vs execution role** — commonly conflated. Execution role pulls the image and writes logs; task role is what your code uses to reach DynamoDB and SQS.
- [ ] **No NAT Gateway** (~$32/mo, the classic trap) and **no load balancer** (~$17/mo). Nothing routes *to* a queue consumer — it reaches out, nothing reaches in.
- [ ] End to end: submit → poll → `PENDING` flips to `COMPLETE` ~10s later, untouched.

## Failure paths

The part most portfolio projects skip, and the part interviews actually probe.

- [ ] **Kill a task mid-message.** Watch the visibility timeout expire and another task pick it up — at-least-once delivery observed rather than recited.
- [ ] **Force a message to the DLQ** and confirm it lands.
- [ ] Be able to explain **why no dedupe table is needed**: analysis is deterministic and overwrites the same item, so duplicates are safe. That reasoning beats bolting one on.

## Cost controls

- [ ] **Scale to zero on queue depth** (min 0 tasks). The difference between ~$0 and ~$44/month of idle Fargate — the main cost lever in the design, not decoration.
- [ ] Short **scale-in cooldown** — scaling to zero costs a 30–60s cold start plus a one-minute Fargate billing minimum, so trickled-in single games otherwise pay startup repeatedly.
- [ ] `terraform destroy`, then `apply` again. If it does not come back clean you have drift or an unclear dependency — find it while the stack is small.
- [ ] Check month-to-date spend is ~zero. If Fargate is not scaling to zero, this is where it shows.

---

## Watch for

- **State drift after console fixes.** Clicking something in the console without reflecting it in Terraform is how the config quietly stops describing reality. If you click, port it back immediately.
- **Scope creep into chess.** The fake worker is the deliverable. PGN parsing, Stockfish, and the aggregate dashboard are all later phases.
- **This will feel too easy** given you already know EC2, Docker and API Gateway. Expected — the deliverable is Terraform-from-commit-one discipline and a pipeline whose failure modes you have personally watched, not novel services.
- **Know the monthly cost and what drives it.** Very few grads can; the skill calls this the interview edge.
