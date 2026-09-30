# Phase 4 — Observability

**Goal:** be able to answer "what happened?" without guessing. Six phases in, the way to find out why something failed is to read raw `print()` output stream by stream and correlate by timestamp. That worked because there is one user who knows the system. It is the thing that stops working first when there is not.

**This phase maps to SOA**, and it is the one the skill singles out: *"this is where student projects are usually empty"*. Every prior phase produced something visible — a queue draining, a chart, a network. This one produces the ability to *see*, which is harder to demo and easier to skip.

**The temptation here is to instrument everything and alarm on nothing that matters.** CloudWatch will happily bill for custom metrics, dashboards and X-Ray traces on a workload that runs a few minutes a day. The rule below decides what gets built: name the question the telemetry answers, and who asks it.

Previous phases: [PHASE-1.md](PHASE-1.md), [PHASE-2.md](PHASE-2.md), [PHASE-3.md](PHASE-3.md), [PHASE-F.md](PHASE-F.md), [PHASE-E.md](PHASE-E.md), [PHASE-6.md](PHASE-6.md). Read them for decisions already made, and do not redo them.

**Two things are owed from earlier phases and are not this phase's work:**
- **Phase F's hosting is still blocked on choosing a domain** — CORS, the browser drills and the public launch all wait behind it. Still the longest-standing open item in the project.
- ~~**Phase E's per-player claim is deployed but never drilled live.**~~ **Drilled 25 Sep:** Hikaru's new September games reached it, and a second `/analyse` six seconds after the first returned `queued: 0, alreadyQueued: 200`. See the finding below — the claim works, but it does not close the duplicates Phase E attributed to it.

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
- **No request IDs anywhere.** Two requests fan out, one queue hop each: submit → ~22 month messages → ingestion, and analyse → ~200 game messages → evaluator. Nothing chains across both services. Nothing ties a worker's log lines back to the request that caused them.
- ~~**Every alarm is a scaling alarm.**~~ *Fixed 29 Sep — the DLQ and game-duration alarms notify by email.* Four exist — `queue-has-work`, `queue-empty`, and the evaluator's pair. All of them exist to *move task counts*. **Not one of them tells you something is wrong.**
- ~~**The DLQ has no alarm.**~~ *Fixed 29 Sep — both DLQs alarm, drilled live.* `check-drift.sh` polls it, but only when run by hand. A message can sit there indefinitely.
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

- [x] **Structured JSON logs — worth the rewrite, or not?** *Decided: JSON everywhere — see the decision log.* The skill lists them. They make lines filterable and metric-filterable, which is what everything else in this phase depends on. The cost is touching all 19 call sites and losing human-readable output when tailing. **Options: JSON everywhere; JSON in the workers only; keep prose and parse it with metric filters.**
- [x] **Request IDs: how far do they need to travel?** *Decided: across the queue — see the decision log.* A request ID is cheap inside one Lambda and real work across an SQS fan-out — it has to ride in the message body and be logged by the worker. Worth deciding whether the goal is per-Lambda correlation or genuine end-to-end tracing.
- [x] **The evaluator's batch outlives its visibility timeout — fix it, and how?** *Decided: `MaxNumberOfMessages=1` — see the decision log. Re-drilled 25 Sep on Tyler1 (`big_tonka_t`, 300 games): **300 evaluations for 300 games, none twice, zero `game_already_evaluated`**, DLQ empty, in-flight held at 8 (one per task), all 300 `game_done` lines carrying the analyse's `requestId`. Median game 37 s, max 149 s — the max alone would have overrun a batch.* Found 25 Sep by the request-ID drill. Each task receives 10 messages and evaluates them serially; games measured **median 53 s, p90 84 s, max 107 s** (Hikaru, 55 games), so a batch needs ~530 s against a **300 s** visibility timeout. The tail of every batch reappears and another task takes it while the first is still busy with earlier games — the worker's `evalDepth` guard misses because the game is not finished anywhere yet. **Result: 236 evaluations for 200 games — 36 done twice (~18% wasted Fargate), 7 more caught by the guard.** DLQ stayed at 0 this run, but each reappearance is a receive, and `maxReceiveCount = 3` means a game can reach the DLQ having never failed. **This also revises Phase E:** its "17 evaluated twice" was attributed to the double `/analyse`, and the claim was said to close both doors — today the claim held and duplicates happened anyway. **Options: `MaxNumberOfMessages=1` (one poll per ~53 s game, negligible); raise the visibility timeout to ~20 min (crashed tasks' games wait that long to retry); extend visibility per message before processing (correct, more code).**
- [x] **Which alarm actually gets built first?** *Decided: the DLQ, on its native SQS metric — see the decision log.* The skill's requirement is "an alarm that demonstrably fires". The DLQ alarm is the obvious candidate: it is the only current failure mode with no human in the loop. **Cost: an SNS topic and email, both ~$0.**
- [x] **X-Ray: yes or no?** *Decided: Lambda tracing only — see the decision log.* The skill lists it. It costs per trace beyond the free tier, and this project's slow path is a *queue wait*, not a call graph — the thing X-Ray is best at showing is the thing Phase 3 already measured by hand. **Name the question it answers that CloudWatch cannot**, or cut it.
- [x] **Dashboard: one, or none?** *Decided: none — see the decision log.* A CloudWatch dashboard is $3/month beyond the first three — real money at this budget. Decide whether the audience is me during a drill (logs are better) or a portfolio screenshot (a dashboard is better).

## To build

Ordered so each piece is verifiable before the next depends on it.

- [x] **Structured logging**, in whatever form is decided above, with the existing useful lines preserved rather than replaced. *Seen live in all three places — ingestion (`fetch_start` → `archive_unchanged`), evaluator (`game_already_evaluated`), and a Lambda (`requestId` on app lines, `platform.report` as JSON). Not yet seen live: the `message_failed` path and link's `lichess_exchange_failed`; the DLQ drill will exercise the former.*
- [x] **Request IDs threaded through** the paths that fan out, so one submit can be followed across services. *Drilled live 25 Sep — see the failure paths below.*
- [x] **A metric filter** turning a log pattern into a number — the SOA-shaped skill this phase is for. *`game_done` → `ChessCloud/GameDurationSeconds`, alarm above 240 s. **Seen matching 29 Sep** on hikaru's live run: a settled window gave 11 log lines and 11 samples, and the max agreed to the decimal (89.4 s; median 47.8). An unsettled window read 49 vs 45 — the newest minutes are not yet published, so compare only closed windows.*
- [x] **At least one alarm that demonstrably fires**, wired to something that reaches me. The skill's wording is deliberate: an alarm nobody has seen fire is an assertion, not a control. *Both DLQ alarms → SNS `chess-cloud-alerts` → email. The analysis one fired and cleared live 29 Sep, and both emails arrived — see the drill below.*
- [x] **`check-drift.sh` extended** to assert whatever this phase decides is load-bearing — most likely the DLQ alarm's existence, since an unnoticed DLQ is the failure this phase is for. *Done 29 Sep. Both queues now (the eval DLQ had never been checked), and per DLQ the whole alert path: alarm exists → actions enabled → SNS action → topic has a confirmed subscription. Each link fails silently on its own. **Seen red:** disabling the eval alarm's actions gave DRIFT and exit 1; the subscription query returned 0 against an empty topic. Not drilled: a missing alarm (same branch as `describe-alarms` returning nothing).*
- [x] **Delete the stray `my-s3-function` log group**, or adopt it into Terraform. It is undeclared state, and Phase 6's whole argument was that undeclared state should not exist. *Deleted 29 Sep. It was the console's S3-trigger Lambda tutorial from 31 Aug, function long gone. **Looking found more:** the tutorial's `my-s3-function-role`, whose policy granted `s3:GetObject` on `arn:aws:s3:::*` — every bucket, the Terraform state bucket included — also deleted; and an empty-environment Elastic Beanstalk bucket from 28 Aug (one 6.6 KB object), left for manual deletion. The log group was the visible symptom; the over-broad role was the one that mattered.*

## What must not change

Carried forward because the temptation to revisit them does not go away.

- [ ] **Ingestion stays pinned at `max_capacity = 1`.** The Chess.com constraint is unchanged, and it is still the one risk money cannot undo.
- [ ] **Scale-to-zero stays.** `MinCapacity == 0` per service, drift-checked. Eight idle evaluators are ~$108/month against a ~$2 budget.
- [ ] **No ALB, no NAT, no RDS.** Phase 6 priced all three and rejected them. Observability is not a reason to revisit any of it.
- [ ] **Both services stay in the purpose-built VPC**, with the task security group holding zero inbound rules. Drift-checked as of Phase 6.

## Failure paths to drill

Same standard as every prior phase: watched live, not asserted. Phase E recorded four bugs that hid behind healthy status, and Phase 6 found that the most dangerous failures are the ones that look like success.

- [x] **The alarm fires for real** → not simulated with `set-alarm-state`. Put a message in the DLQ and watch the notification arrive. *Done 29 Sep, through the real path: a poison body (a `requestId`, no `id`) sent to the ingestion queue at 11:30 UTC. Three `message_failed` lines exactly 180 s apart, each carrying the `requestId`, `messageId` and `KeyError 'id'` — the first live sighting of that path. Alarm OK → ALARM at 11:47:40, **~18 min from send to email**; both the ALARM and OK emails arrived. The dead message kept its `requestId`, so the correlation survives redrive. Findings:*
  - ***The move to the DLQ needs a consumer.*** *SQS moves a message on the receive **after** `maxReceiveCount`, not when the third timeout expires. The worker had scaled to zero, so the move waited for a fresh scale-out — ~6 of the 18 minutes.*
  - ***Ingestion scales in with a message in flight.*** *Its scale-in alarm counts visible messages only — the bug Phase E fixed for the evaluator. Harmless for ~1 s messages; for a failing one it only adds delay. Left as is.*
  - ***`ok_actions` also fires when an alarm is created*** *(INSUFFICIENT_DATA → OK), so any apply that recreates an alarm sends an OK email.*
- [x] **A request is followed end to end** → pick one submit, find every line it produced across both services, and confirm the correlation actually works. *Done 25 Sep with a real authenticated token.* Submit `d00fc6f2…` → `submit_queued` (1 month) → worker `fetch_start` + `archive_done`, same ID. Analyse `2ad302fb…` → `analyse_queued` (200) → **all 236 `game_done` and 7 `game_already_evaluated` lines across 8 evaluator tasks carry it**. A second analyse `d57dd8ef…` logged `analyse_already_queued` and appears on **zero** worker lines — correct, since it queued nothing. The only lines without an ID are per-task lifecycle lines (`evaluator_up`, `evaluator_exit`), which belong to no request.
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
| Log format | **JSON everywhere.** Workers: stdlib `logging` with a small formatter. Lambdas: the runtime's native JSON log format. Both use the same key names, so one query spans every log group | JSON in the workers only; keep prose and parse it with metric filters | A metric filter on prose is coupled to exact wording — reword a line and the metric flatlines while the alarm stays green, the failure that looks like success. JSON also gives a request ID a field to live in. Lambdas use the native format because each ships as a single-file zip, and it stamps `requestId` on every line for free |
| Request IDs | **Thread the Lambda's own `requestId` through the queue.** submit and analyse put it in each message body; the workers log it on every line for that message. Evaluator lines also gain `pk` | Per-Lambda only (what native JSON already gives); natural keys only (`analysis_id`, `sk`) | Natural keys identify the *thing*, not the *request* — and this app deliberately lets two requests touch the same keys. The deciding case is the DLQ: a dead message body should say which request created it, so one query finds the Lambda's side and every retry. Cheap because each fan-out is one hop. Reusing Lambda's ID means no second ID to reconcile |
| Evaluator receive size | **One message per receive** | Raise the visibility timeout to ~20 min; extend visibility per message before processing | A batch starts every message's timeout at the receive, so ten ~53 s games overran 300 s and the tail was evaluated twice (36 of 200). One per receive makes each timeout start with its own game; the extra poll is ~0.1 s beside the engine. A 20-min timeout keeps batching but makes a crashed task's games wait 20 min to retry. Per-message extension is correct but costs the same extra call per game, plus code. Limit: a single game over 300 s would still overrun — measured max is 149 s |
| First alarm | **DLQ depth > 0, on the native SQS metric `ApproximateNumberOfMessagesVisible`**, notifying by SNS email | An alarm on a metric filter over `message_failed` lines | The DLQ is the only failure with no human in the loop, and a message there has genuinely given up. `message_failed` fires on every attempt, including the retries that succeed, so it would alarm on failures that fix themselves. Native SQS metrics are free and the alarm is inside the free ten. Cost: slow to fire — ~15 min of retries plus ~5 min of SQS metric lag — acceptable for "something died unnoticed" |
| Metric filter | **Per-game evaluation time** — `duration_s` on `game_done`, timed from the receive; alarm on its Maximum above 80% of the eval queue's visibility timeout (read from the queue root, so the two cannot drift apart) | Count `message_failed` as a metric with no alarm | Guards the stated limit of the one-per-receive fix: a game that outlives its timeout is evaluated twice and nothing fails. A failure count answers nothing the DLQ alarm does not. Maximum, not average, because one slow game is the failure |
| X-Ray | **Active tracing on all six Lambdas; no SDK, no workers.** One setting and one IAM statement per function, no code or packaging change | Full end-to-end with the workers (a daemon sidecar per task, trace context threaded through SQS by hand); cut it | The question arrived before the tool: over 30 days `/player` averaged **4.1 s**, worst **24 s** against a 25 s timeout, and `analyse` hit its 20 s timeout at least once — REPORT lines give only the total. Traces split it: cold start 0.46 s, warm handler **2.6 s for 10,865 games vs 0.5 s for 1,502**. Workers excluded because their slow parts — queue wait and Stockfish — are already visible in logs. The SDK (per-call timing) breaks the single-file zips and was not needed: replaying the query showed the cause directly. ~$0, inside the 100k traces/month free tier |
| Lambda errors alarm | **One alarm on Lambda's account-wide `Errors`** (no function dimension), to the same SNS topic, alarm and OK | One alarm per function; API Gateway `5xx` | X-Ray's first look found `analyse` had hit its 20 s timeout with nothing telling anyone. Account-wide is one metric, free, and covers functions added later; the email does not name the function, the query in its description does. `5xx` was rejected because it also counts the handled 502/503s for Chess.com or Lichess being down — upstream outages, not actionable. **Drilled 29 Sep:** a malformed direct invoke of `player` raised `AttributeError`; ALARM 28 s later. **The drill caught a wrong runbook:** the description's query found nothing — the runtime logs crashes under `log_level`, not the app's `level`, and in JSON format a timeout is `status: timeout` on `platform.report`, not "Task timed out" text (a crash's report says `status: success`). Fixed and re-tested. The timeout branch is still unproven: the only real timeout is older than the 14-day retention |
| `/player` and `analyse` selection | **A `by-class` GSI** — partition `classKey` (player + time control), sort `SK`, holding keys and `evalDepth` only. One `Limit 100` query per class; `excluded` from the month summaries. Still derived on read — no counter | More Lambda memory; a stored per-player counter | X-Ray showed the time was the handler, and replaying the query showed why: selection walked a player's games until the **rarest** class reached 100, and a Query pays for whole ~2.6 KB items. 22 of 28 pages for big_tonka_t, 43 for hikaru, **the whole history for anyone with under 100 games in a class**. Memory would only have slowed the growth. A counter breaks Phase E's rule. **Verified 29 Sep:** the index returns the identical games, order and `evalDepth` for all three players; responses identical except `excluded`, now exact (hikaru: 188 daily, previously suppressed as partial). Warm: `/player` big_tonka_t 2,646 → **225 ms**, hikaru ~23 s worst → **499 ms**; `analyse` hikaru, which timed out at 20 s → **366 ms**. Cost: a one-off backfill of 83,091 games (~$0.25–0.50) and an index write per game written. **Found on the way:** the backfill, at 16 threads, died on `ThrottlingException` after ~66k — hikaru's 70k games land on three index keys, and a hot GSI key throttles the *table*. Re-run at 4 threads with adaptive retries. Eventual consistency accepted: progress may lag a second, and a re-queued game is absorbed by the evaluator's `evalDepth` guard |
| Dashboard | **None** | One CloudWatch dashboard | Every question this phase actually answered was answered by logs, a trace or a replayed query — never by a chart. The audience during a drill is me, and logs are better there. Not a deviation: the skill's Phase 4 row does not list one. $3/month past the first three is real money on a ~$2 budget for something nothing here would read |
| Analyse button after a refresh | **`/player` returns `evaluation.running`, read from analyse's per-player claim**; the page shows a run as live if it started it *or* the server says so. The read fails open | Keep it page-local; infer from `outstanding > 0` | A refresh mid-run offered Analyse again and hid progress — harmless (the claim answers `alreadyQueued`, no token) but wrong. `outstanding > 0` also describes a never-analysed player, the bug the page-local state fixed. Mirrors the claim's 20-min expiry, so the button returns exactly when a click would be accepted — which for a full ~25-min run is before it ends; that is the claim's limit, not the display's. **Deploying it caused a real outage:** code and IAM grant in one apply gave **~5 min of 500s** on every `/player` (69 errors) while the policy simulator said *allowed*. It cleared seconds after a code-only redeploy started fresh environments — which suggests warm environments kept the denial, though unconfirmed. **The Lambda errors alarm fired 17 s after the first 500** — the first alarm here to catch a failure nobody staged. Hence fail-open: an advisory read must not be able to take down the page |

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
