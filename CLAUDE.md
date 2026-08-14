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

**Still open:** _none — all Phase 1 decisions made._

### Open question for Phase 2 — authentication

Nothing currently stops anyone with a valid game id from reading that game. Ids are hard to guess, which is not access control. The id format never protected anything; verifying *who is asking* does.

Three options, undecided:

- **Lichess OAuth2** — open, standard PKCE flow, no application or approval needed. Verifies the chess identity itself, which maps directly onto `PK = USER#<userId>`.
- **Chess.com OAuth** — exists, but access is gated behind an application and approval, aimed mainly at connected-board and login integrations. Timeline not under our control. Awkward given the roadmap picked Chess.com's Published Data API for ingestion.
- **Plain Cognito** — no chess-platform SSO; the app owns its own accounts. Simplest to build, but a user's chess username would then be a claim rather than something verified.

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
| Game lookup | Composite id — the id *is* the key | GSI on `gameId`; `PK = GAME#<gameId>` | DynamoDB computes an item's location from the partition key rather than searching, so a bare `gameId` would force a Scan. A GSI is eventually consistent — a poll right after submit could 404 on a game that exists — and roughly doubles write cost. `PK = GAME#` would break listing a user's games. |
| Id delimiter | `-` (`hikaru-1723526400-abc123`) | `.`; `#`; base64url | Conventional in URLs. In a URL path everything after `#` is a fragment and never reaches the server. Base64 is encoding, not encryption — one command decodes it — so it buys no privacy while making logs harder to read. Stored keys still use `#`. |
| Id parsing | `rsplit("-", 2)` + hyphen-free gameIds | `split("-")` | Chess.com usernames may contain hyphens, so splitting left-to-right mis-parses `a-b_c1-...` into four parts and rebuilds the wrong key. Splitting from the right takes the last two fields — timestamp and gameId — and leaves the username whole. Requires gameIds with no hyphens: use `uuid4().hex`, not `str(uuid4())`. |
| Visibility timeout | 180s | 60s tuned to the fake worker | Sized for real analysis (30–90s/game) so the value never changes underneath us. Too short means a second worker starts a game the first is still analysing; too long means a crashed worker's message waits before retry. 3min of dead time is invisible at this scale. |
| Max receives | 3 | 5; 2 | Rides out a transient crash or Spot reclaim, but quarantines a genuinely poison game fast — each retry costs a full analysis attempt in Fargate time, which is the thing actually billed. |
| API flavor | HTTP API | REST API; Lambda Function URLs | Same job as REST at ~$1/M vs ~$3.50/M; the REST-only extras (API keys, usage plans, caching) have no consumer here, and HTTP API's built-in JWT authorizer is the slot Phase 2's OAuth choice plugs into. Function URLs are $0 but give two bare URLs with no routing and no authorizer — a roadmap deviation with nothing bought. |
| Scale-in cooldown | 5 min of empty queue | 2 min; 15 min | Covers a user submitting games one at a time while thinking, so trickle traffic does not pay a 30–60s cold start plus the one-minute Fargate billing minimum per game. Lingering costs ~$0.001 per occurrence at this task size — the asymmetry favours patience. |
| Worker capacity | Fargate Spot | On-demand Fargate | ~70% cheaper, and a reclaim mid-message is the same at-least-once path a crash exercises — max receives = 3 already budgets for it. At scale-to-zero volume the savings round to zero; the real value is watching a reclaim happen in a phase built for observing failure modes. |
| Lambda timeout | 10s both | 3s; 29s | Real work is <1s; the timeout only bounds a hung dependency. 3s can kill a cold start plus one SDK retry that was going to succeed; 29s makes every client wait the full gateway cap to learn of a failure. |
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
- [x] Directory layout: `app/handlers/` for Lambda code (worker will live in `app/worker/`), one Terraform root per layer under `terraform/`.
- [x] `terraform fmt` and `validate` runnable before anything is applied.

## DynamoDB — the data store

**What it is for:** holds each game's status and, later, its analysis. Chosen over a relational database because this app has exactly two fixed access patterns and no need for joins or ad-hoc queries. With fixed patterns, DynamoDB is the *better* answer, not just the cheaper one.

Settle the keys **before** the table exists. A wrong partition key means a data migration; a wrong Lambda timeout is a one-line fix.

- [x] Access patterns confirmed: get game by id; list a user's games newest first.
- [x] Keys settled: `PK = USER#<userId>`, `SK = GAME#<timestamp>#<gameId>`. The timestamp leads the sort key, so newest-first comes straight from storage order — no sorting in application code.
- [x] Both patterns served without a secondary index — proven against the live table.
- [x] **Billing: on-demand** — see decision log.
- [x] Table live (`chess-cloud-games`), both patterns verified with real items, test data removed.
- [ ] Check worst-case analysis payload against the 400KB per-item limit, before the engine generates real eval data. *(Nothing to measure while the worker is fake — revisit when Stockfish lands.)*

**Measured, for the interview answer:** a Scan filtering on a bare `gameId` read every item in the table to return one (`ScannedCount` 3, `Count` 1, 2.0 capacity units). The same fetch via composite id cost 0.5 units and read exactly one item. A 4× gap at three items, unbounded as the table grows — which is the whole reason the id carries the key.

**Two rules the submit Lambda must honour** (both enforce the id format, not the table):

- Generate gameIds with **no hyphens** — `uuid4().hex`, never `str(uuid4())`, which is hyphenated and would corrupt parsing.
- Parse with **`rsplit("-", 2)`**, never `split("-")`. Usernames may contain hyphens; the timestamp and gameId never do, so taking the last two fields from the right is what keeps a username like `a-b_c1` intact.

## SQS — the queue

**What it is for:** three jobs at once. It **decouples** submit from analysis so the API can answer immediately. It **load-levels** — a 500-game upload is accepted in a second and drained at whatever rate the worker manages. And its depth is the **autoscaling signal**, which is what makes scale-to-zero possible.

The DLQ catches messages that fail repeatedly, so one bad game cannot block the queue forever.

- [x] Queue and DLQ created together — retrofitting a DLQ after a poison message is worse.
- [x] **Visibility timeout: 180s.** Sized for real Stockfish analysis (30–90s/game), not the 10s fake worker, so it never needs revisiting when the engine lands.
- [x] **Max receives: 3** before redrive to the DLQ.
- [x] **Long polling (20s).** The default of 0 is short polling — the worker asks, gets an instant "no", and asks again in a tight loop, burning CPU and API calls while idle.
- [x] Redrive proven on the live queue: receive counts climbed 1 → 2 → 3, the message vanished from the main queue on the 4th attempt, and arrived in the DLQ with its body intact.

**Learned while testing:** `ApproximateNumberOfMessages` lags in *both* directions — observed reporting 1 for an already-empty DLQ, and 0 for a DLQ that held a message. `check-drift.sh` therefore polls the DLQ rather than reading the counter: a check that reports "all clear" when it is not is worse than a slow one. Costs a few seconds per run; it never deletes, and receives at visibility 0 so anything found stays available to the real worker.

Queue depth being approximate is fine for autoscaling — cooldowns absorb it — but not for a correctness check. A CloudWatch alarm on DLQ depth is the proper push-based answer and belongs in Phase 4 with the rest of the alarms.

**Correction:** `redrive_allow_policy` restricts which queues may redrive *into* the DLQ. It does **not** block a direct `SendMessage` — that succeeded in testing. Keeping redrive the only real path into the DLQ is an IAM job, handled when the Lambda and worker roles are scoped.

## Lambda + API Gateway — the front door

**What they are for:** two small functions that run only when called and cost nothing idle. API Gateway is the HTTP front door; Lambda is the code behind it.

- **Submit** — accept the request, record it as `PENDING`, put a message on the queue, return `202` immediately with a URL to poll.
- **Status** — look up one game and return it. The client polls this. No websockets.

Neither does real work. That is the design: analysis takes 30–90 seconds, and API Gateway hard-caps a request at **29 seconds** regardless of Lambda's own timeout. Queuing is not optional here — it is what the ceiling forces.

- [x] Both functions live behind API Gateway — HTTP API (see decision log), throttled to 10 req/s while the API has no auth.
- [x] Each has its own role, scoped to just the table and queue it touches. No wildcards — submit gets `PutItem` + `SendMessage`, status gets `GetItem` only, logs scoped to each function's own pre-created log group.
- [x] End to end: post a payload → `202` + id → item appears in DynamoDB → message appears in SQS → status URL returns `PENDING`. Verified live (hyphenated username, malformed-id 400, missing-game 404); test data removed.

## Fargate — the worker

**What it is for:** the analysis job that Lambda cannot do. Later it runs Stockfish — a heavy native binary, CPU-bound, on batches that blow past Lambda's 15-minute ceiling, and it benefits from keeping a warm engine process between games. This is the rare case where "why not Lambda" has a real answer.

Fargate means containers without managing servers. **In Phase 1 the worker is fake:** receive a message, sleep 10 seconds, write a hardcoded result. Get the plumbing right before the engine arrives.

- [x] ECR repository — where the container image lives so ECS can pull it. Lifecycle policy keeps the last 5 images.
- [x] Worker loop: long-poll queue → sleep → write result → mark `COMPLETE` → delete message. Result written *before* delete — the ordering that makes at-least-once safe.
- [x] ECS cluster, task definition, service. Fargate Spot (see decision log), 0.25 vCPU / 512MB.
- [x] Understand **task role vs execution role** — implemented as two scoped roles: execution pulls the image and writes logs (fails there = execution-role problem); task role is receive/delete on the queue + `UpdateItem` on the table (AccessDenied in code = task-role problem). Neither touches the DLQ, closing the IAM half of the redrive finding.
- [x] **No NAT Gateway** and **no load balancer** — default-VPC public subnets, public IP, security group with zero ingress rules.
- [x] End to end: submit → poll → `PENDING` flips to `COMPLETE`, untouched. ~10s when warm; ~2.5min from cold (SQS metric lag + 60s alarm period + task provisioning) — the price of scale-to-zero, acceptable by design.

**Learned while testing:** ECS stop = SIGTERM, 30s grace, then SIGKILL. The fake worker's 10s job always finishes inside the grace, so a plain `stop-task` *cannot* interrupt it mid-message — the graceful path completes the game and deletes the message. Observing the ungraceful path required a temporary 2s `stopTimeout` (reverted). The real engine's 30–90s games will overrun the grace naturally, so both paths matter.

Also observed: the queue-empty alarm watches *visible* messages, so it can scale the worker in while a message is still in flight. Safe by design — the message reappears via visibility timeout and re-trips the scale-out alarm — but it means a kill near scale-in costs one extra cold start. Watched it happen; self-healed.

## Failure paths

The part most portfolio projects skip, and the part interviews actually probe.

- [x] **Kill a task mid-message.** Observed live: SIGKILL 5s into processing → no delete → game stayed `PENDING` through the 180s visibility timeout → a fresh task received the *same message a second time* → `COMPLETE` ~5.5min after the kill. Nothing lost.
- [x] **Force a message to the DLQ** and confirm it lands — this time through the real worker's leave-on-failure path, not a manual consumer: worker logged `failed, leaving for retry/DLQ`, receive count climbed to 4 across 180s visibility cycles, message landed in the DLQ ~12min after send, body intact. One bad game can no longer block the queue, and the worker never deletes what it failed to process.
- [x] **Why no dedupe table:** demonstrated, not recited — the kill drill delivered one message twice and the second delivery simply overwrote the same item with the same result. Deterministic analysis + idempotent write = duplicates are a non-event.

## Cost controls

- [x] **Scale to zero on queue depth** (min 0 tasks). Step scaling on `ApproximateNumberOfMessagesVisible`: any message → 1 task, empty for 5min → 0. Watched it cycle 0→1→0 live. (Target tracking can't start from zero — every per-task ratio is undefined at 0 tasks.)
- [x] Short **scale-in cooldown** — 5 minutes, see decision log.
- [ ] `terraform destroy`, then `apply` again. If it does not come back clean you have drift or an unclear dependency — find it while the stack is small.
- [ ] Check month-to-date spend is ~zero. If Fargate is not scaling to zero, this is where it shows.

---

## Watch for

- **State drift after console fixes.** Clicking something in the console without reflecting it in Terraform is how the config quietly stops describing reality. If you click, port it back immediately.
- **Scope creep into chess.** The fake worker is the deliverable. PGN parsing, Stockfish, and the aggregate dashboard are all later phases.
- **This will feel too easy** given you already know EC2, Docker and API Gateway. Expected — the deliverable is Terraform-from-commit-one discipline and a pipeline whose failure modes you have personally watched, not novel services.
- **Know the monthly cost and what drives it.** Very few grads can; the skill calls this the interview edge.
