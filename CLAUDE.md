# Phase E — Stockfish

**Goal:** make "analysed" mean *evaluated*. Phase 3 made it mean *counted* — games, W/D/L, colours, time controls, ratings — a real aggregate a dashboard can render, deliberately shipped without an engine. This phase adds the engine that makes this a chess project rather than an ingestion pipeline.

**This is the phase the roadmap never scheduled.** The numbered phases map to certifications — 3 is ingestion, 6 is VPC, 4 is observability, 5 is CI/CD, 7 is load and cost — and none of them is "add Stockfish". The plan said "Phase 1 uses a fake worker… then swap the engine in" and never named when. Named **Phase E**, after **Phase F** because the engine's output is visual: eval graphs, annotated moves, blunders by phase. Building it before anything can display it makes it hard to judge whether the analysis is any good.

Previous phases: [PHASE-1.md](PHASE-1.md), [PHASE-2.md](PHASE-2.md), [PHASE-3.md](PHASE-3.md), [PHASE-F.md](PHASE-F.md). Read them for decisions already made, and do not redo them. **Phase F is complete except hosting**, which is blocked on choosing a domain — CORS, the browser drills and the public launch all wait behind it.

Account: `961868442307` · Region: `ap-southeast-1` · IAM user: `terraform-admin` (MFA enabled)

---

## How we work on this

Unchanged since Phase 1, and still the point of the exercise. This project is a learning exercise; the deliverable is understanding, not a finished stack — a working stack I cannot explain is a failed phase.

**Claude writes the code. I make the decisions, after I understand them.**

- **Explain first, then write.** Before adding a service: what problem it solves in *this* app, what breaks without it, what it costs. Then I decide, then you write it.
- **Ask, don't assume.** Any choice with a real trade-off — service selection, retry policy, storage layout, what counts as done — is mine. Present the options and what each costs, then wait.
- **Name the failure mode** a service exists to handle here. If the honest answer is "real systems use it", it gets cut — that rule cut S3 in Phase 3 and the automated spending stop in Phase F.
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

*Access note: the skill is not readable from the CLI. It is exported as `aws-cert-plan-phase3.skill` (a zip containing `SKILL.md`) and unpacked. **One inconsistency to fix on the next update:** its architecture section still says "Stockfish lands here in Phase 4", contradicting its own Phase E section which calls that "wrong twice over" — a leftover from the Phase 3 rewrite.*

Run `bash scripts/check-drift.sh` after every apply.

---

## Settled — the decisions this phase rests on

Made before any engine code, because each one determines what gets written.

### Storage: one item per game — **built and migrated**

`SK = GAME#<yyyy-mm>#<id>` alongside `ARCHIVE#<yyyy-mm>`. Evals ride on the game item, projected away for list reads.

**Per-ply evals cannot share the month item under any encoding.** Measured: the heaviest real month (danielnaroditsky 2024-03) is 2,815 games and **499,444 plies**, so evals alone are **975 KB against a fixed 400 KB limit** — 2.4× over before the existing rows count. Per-game items are ~906 B, **0.2% of the limit**.

**It fixed a live problem the engine did not create.** That month was at **~380 KB — 95% of the limit** from game rows alone, measured as 47.5 RCUs. Phase 3's documented ceiling of 2,288 games came from an estimate of 179 B/game; the real encoding is 138, so the month sailed past the stated ceiling and stored anyway. A month ~5% heavier would have failed to write with **no failure path for it** — a generic error, three retries, into the DLQ looking exactly like a Chess.com outage.

- [x] **Migrated 26 Aug 2026** — 393 months, **147,214 games**, zero sort-key collisions. *(That data was deleted 30 Aug 2026 — see The existing data below. The migration stands as the reason the per-game shape exists; the rows it moved are gone.)* That item now reads at **0.5 RCUs instead of 47.5**. All routes verified afterwards; every player's month and game counts unchanged.
- [x] **Reads tolerate both shapes** — the inline array wins when present, otherwise a paginated Query. That is what let the migration run as a background job rather than a flag day.
- [x] **Phase 3's atomicity argument replaced by ordering.** Games are written first, then the month flips to `COMPLETE`. A crash between the two leaves the month not-`COMPLETE` and the message replays over the same keys. **Proven under a real failure**, not argued: the worker's first run lacked `BatchWriteItem`, failed three times to the DLQ, and the month stayed `PENDING` throughout.
- [x] **Stale games are deleted after the write** — a re-fetch can return fewer games than before, and orphans would otherwise accumulate.

**Four bugs only deploying could find**, the same pattern Phase 3 recorded: `status` lacked `dynamodb:Query`; the worker lacked `BatchWriteItem` **and** `Query` (a distinct action, not a variant of `PutItem` — exactly as `SendMessageBatch` was); the directory `Scan` counted game items as months, which would have turned 149 months into 129,391; and an IAM fix *appeared* not to work because the Lambda's **cached execution environment held pre-change credentials** — `simulate-principal-policy` said allowed while the function still returned AccessDenied.

**Sequencing mistake worth keeping:** the first player was migrated *before* the reader that understands the new shape was deployed, so its games briefly read as zero. Correct order is reader first, then data.

### Two operations, not one

Fetching a profile and analysing a game are separate requests with separate limits.

| | Profile fetch (`POST /games`) | Game analysis (new route) |
|---|---|---|
| What it does | Archive list, months, per-game rows, counts | Stockfish over one game's plies |
| Engine | **No** | Yes |
| Talks to Chess.com | Yes — stays serialised, `max_capacity = 1` | **No** — reads the stored PGN |
| Bound | Chess.com's rate | Last 100 games per time control |
| Who may | Anyone registered | Anyone registered, rate-limited |

**The basic statistics are always shown.** Everything Phase 3 built needs no engine and stays open to everyone; evaluation statistics are a *second* group on the page, populated only for games actually analysed. The split still matters even without a verification gate: profile fetch is unbounded and cheap, analysis is bounded and expensive, and they answer to different limits.

### Store the PGNs

**This is what makes scaling safe.** Evaluation must not re-fetch moves from Chess.com: that would put the engine back behind the serialised worker pin and undo the reason for splitting the two.

Measured: PGNs are **3,151 B mean**, max 8,872 B — a game item goes from 138 B to ~3.3 KB, **0.8% of the limit**. Impossible before the migration: 8.9 MB of PGN for the heaviest month could never have shared one item.

| Storage at $0.25/GB-month | | |
|---|---|---|
| Everything currently ingested (147,214 games) | 0.48 GB | **$0.12/mo** |
| 1,000 users × 3,000 games | 9.9 GB | **$2.47/mo** |
| 10,000 users × 3,000 games | 98.7 GB | $24.67/mo |

**Storage is the one cost here that recurs.** Compute is one-off per game; PGNs bill every month whether anyone analyses them or not, and arrive whether or not anybody uses the engine.

### Evaluation scales; ingestion does not

**The worker pin does not apply to evaluation, and that is the point.** `max_capacity = 1` exists to protect Chess.com's API — an IP ban is the failure mode money cannot undo. Evaluation reads a stored PGN and runs a local binary, making **zero upstream requests**. This is the scaling question [PHASE-F.md](PHASE-F.md) could not resolve, and it dissolves not by establishing Chess.com's limit but by removing Chess.com from the path.

**Concurrency buys latency, not cost** — Fargate bills per vCPU-second. At depth 18 (55.6 sec/game at 1 vCPU) with the last-100-per-control cap:

*(Figures below are the pre-measurement estimates that justified scaling. Both numbers moved afterwards: games are **31.4 s not 55.6 s**, and daily is no longer evaluated. Current figures are in the cost table under Infrastructure.)*

| | Games | 1 worker | 10 workers | Cost |
|---|---|---|---|---|
| theohwk | 227 | 3.5 hr | 21 min | $0.053 |
| danielnaroditsky | 318 | 4.9 hr | 29 min | $0.074 |
| erik | 361 | 5.6 hr | 33 min | $0.084 |

**Ten workers is what makes depth 18 usable.** Half an hour is a wait someone will tolerate for a full-depth report; five hours is not.

### The last 100 games per time control, at depth 18

**Not every game, and not a shallow depth.** Both halves of the earlier plan were wrong, and measuring is what showed it.

**Depth 8 does not work.** Benchmarked against depth 18 over 10 real games (1,047 plies):

| Depth | Blunders found | Missed | False+ | Recall | Avg centipawn loss |
|---|---|---|---|---|---|
| 8 | 32 | **24** | 5 | **53%** | 111.7 cp |
| 12 | 40 | 18 | 7 | 65% | 143.1 cp |
| 18 | 51 | 0 | 0 | 100% | **217.2 cp** |

The reasoning behind depth 8 — "a blunder is a large eval swing and does not need deep search" — sounded right and is false: a shallow engine does not *see* the refutation, so the position does not look bad to it yet. It misses nearly half of real blunders, and on the looser mistakes band **46% of what it flags is not a mistake at all**. Worse, it reports roughly **half** the true average centipawn loss, which makes the dashboard's headline number flattering rather than merely imprecise. Chess.com uses depth 18–30 depending on tier.

**Bounding the games instead of the depth is what makes depth 18 affordable.** 100 games per time control, at $0.00023/game:

| | Games | Cost |
|---|---|---|
| erik | 361 | $0.084 |
| danielnaroditsky | 318 | $0.074 |
| theohwk | 227 | $0.053 |
| **Worst case** (4 controls × 100) | 400 | **$0.093** |

*(Superseded: worst case is now 3 controls × 100 = 300 games at **$0.043**, daily having been cut and the per-game rate measured. The reasoning for bounding games rather than depth is unchanged, which is why this table stays.)*

**Per time control, not overall**, because a player's last 100 games overall can be entirely one control — theohwk's would be nearly all rapid, hiding 437 blitz games. 4× the cost of last-100-overall and worth it.

**danielnaroditsky stops being expensive.** 129,391 games becomes 318, the same as everyone else. The outlier problem this phase kept running into simply disappears.

### No verification — the bound is the work, not the asker

**Cut.** The profile-token flow, the `verified` gate and the one-at-a-time restriction all existed to stop a single user running up unbounded cost. With a fixed per-player ceiling there is no unbounded cost to run up.

Three things bound it together:

1. **A hard cap per player** — 100 games per time control, so no player is expensive
2. **Skip already-evaluated games** — a player is paid for once, ever, by whoever asks first
3. **Analysis is keyed by player, not user** — Phase 3's decision, now doing double duty

**Re-submitting an already-analysed player costs $0.00.** The only way to spend money is submitting *distinct, never-before-analysed* players, and the dedup improves with use: the more players analysed, the more submissions are free.

**The residual risk is scripted distinct usernames** — 10,000 players is $930 worst case. That is what a **rate limit** handles, which [PHASE-F.md](PHASE-F.md) already lists as owed and which is cheaper to build than verification. A registered account plus N submissions per hour is the whole control.

---

## To build

### Bounding the work

- [x] **Select the last 100 games per time control** for a player, newest first, and evaluate only those. Selection lives in the analyse Lambda rather than the worker — it is a question about the table, and answering it once at the front door beats every worker re-deriving it. Proven on theohwk: **201 games** selected as 100 blitz, 100 rapid, 1 bullet — the 26 daily games are excluded before the cap applies, so dropping them does not free a slot for another control. *(The original run selected 227 including daily; the cut is recorded in the decision log.)*
- [x] **Skip games that already have evals.** This is what makes re-submission free, and it must be **per game, not per player**: a player analysed last month has 100 evaluated games, but their newest 100 now includes games played since. Per-player skipping would never pick up new games; per-game re-evaluates only the delta, typically a handful. The same insight as the ETag, one layer down. Filtered on `evalDepth == DEPTH` at selection, and again in the worker so a duplicate SQS delivery costs a `GetItem` rather than 45 seconds of engine — **true only once the first pass has finished**, which is what the in-flight claim below exists to cover.
- [x] **Rate limit on analyse** — a **token bucket per account**: 5 tokens, refilling one per hour. Replaces verification entirely and settles the debt to [PHASE-F.md](PHASE-F.md) — one control, two purposes.

  **Charged per distinct new player, not per request.** The bucket is debited *after* selection and only when `todo` is non-empty, so re-submitting an analysed player queues nothing and costs no quota. That is not a nicety: if free requests burned tokens, the dedup would stop being free and the case for cutting verification would collapse with it.

  **A bucket rather than a flat 1/hour**, because the product is comparing players — one per hour makes looking at yourself and two friends a three-hour job. Bursting five keeps first use normal while sustained use still converges to one per hour, ~$1.03/day at the measured $0.043 worst case.

  **One conditional `UpdateItem`, not read-then-write.** The condition carries the decision, so a failed condition *is* the rejection. Read-then-write is a race two parallel requests win together — the exact bug a rate limit exists to prevent. Drilled: two requests reading the same state, exactly one wins, tokens never go negative. Refill is computed from `updatedAt` rather than scheduled, advancing by whole periods so a partial hour is neither refilled nor rounded away, and the row is swept by the same TTL the OAuth flow uses.

  **`POST /games` deliberately has no bucket.** Ingestion is bounded by the worker pin, which serialises upstream traffic however deep the queue gets, plus the existing 10 req/s stage throttle.

- [ ] **Account registration is the hole this does not close** *(future work)*. The bucket bounds an **account**, and accounts are free — someone willing to register 50 multiplies the limit by 50. This is a real limit of the control, stated rather than papered over: it makes casual abuse impossible and determined abuse slow and visible, which is proportionate here, but it is not a cap on spend. **The budget alarm remains the actual backstop.** Options if it ever matters: email verification before `/analyse` (Cognito supports it, one setting, annoying for real users); a global daily ceiling across all accounts, which caps total spend regardless of how many accounts exist and is probably the cheapest real fix; or per-IP limiting, which WAF does at ~$5/month — more than the entire budget. **Not built, and deliberately so:** none of it is worth building before anyone is actually using this.
- [x] **Any user may analyse any player.** Analysis stays public shared data, so a popular player is evaluated once for everyone. `POST /analyse` is authenticated but takes any username; the caller's `sub` rides along as `requestedBy` for attribution only, never as a key.

### The engine

- [x] **Stockfish in the image.** One `apt-get install stockfish` layer, plus `chess` for PGN parsing and UCI. **One image serves both workers** — the task definition picks which by overriding the command — because they share the table, the row shape and most of their operational story. GPL-3 is satisfied: the binary is unmodified Debian, distributed to nobody, and reached only over HTTP.
- [x] **One engine process, reused.** A module-level `_engine()` started on first use and kept for the task's life, not per message — starting Stockfish and loading NNUE weights is a real share of a 45-second job. This is the skill's stated reason for Fargate over Lambda, so throwing it away would have removed the justification for the platform.
- [x] **Depth settled at 18** — measured, not assumed. See the settled section above for the recall numbers that ruled out 8 and 12. **31.4 s/game at 1 vCPU**, measured — not the 55.6 s originally assumed.
- [x] **Separate route** — `POST /analyse`, against an already-ingested player. 404 if nothing is stored, so a request for impossible work fails at the front door rather than as messages that reach the DLQ looking like a real fault. Returns 202 with `queued`, `skipped`, `byClass`, `excluded` and — when a run is already in flight — `alreadyQueued`, because a saving that is not reported is only claimed.
- [x] **Ingestion stores the PGN** on the game item, via `summarise_game()`. Measured at 3,151 B mean against a 400 KB limit.

### Infrastructure

- [x] **Separate queue and service** for evaluation, so ingestion stays pinned at 1 and evaluation scales independently. `check-drift.sh` now asserts `MaxCapacity` **scoped to the ingestion worker only** — the evaluator is deliberately exempt, because it is the one service whose ceiling is a tuning knob rather than a guard.
- [x] **Task sizing.** Ingestion stays 0.25 vCPU / 0.5 GB; the evaluator runs **1 vCPU / 2 GB** with `Threads: 1` and a 128 MB hash. One thread per task rather than four per task, because SQS already parallelises across tasks and Stockfish scales better across processes than threads at fixed depth.
- [x] **Re-measure the per-month cost** with the engine in the loop. Phase 3's $0.000186/month and $0.028/player were ingestion-only and did not survive — but **evaluation came in cheaper than planned, not dearer**, because games take 31.4 s rather than the assumed 55.6 s. At Spot rates for 1 vCPU / 2 GB that is **$0.000143/game**, 62% of the $0.00023 this file budgeted:

| | Games | Cost | 1 task | 8 tasks |
|---|---|---|---|---|
| **theohwk** *(measured 31 Aug)* | **201** | **$0.029** | 1.8 hr | **13.9 min** |
| danielnaroditsky | ~292 | $0.042 | 2.5 hr | 20 min |
| erik | ~335 | $0.048 | 2.9 hr | 23 min |
| **Worst case** (3 × 100) | 300 | **$0.043** | 2.6 hr | 21 min |

theohwk's row is no longer an estimate: **201 games in 13.9 min on 8 tasks**, end to end. The others are scaled by the same measured rate, with daily removed from their counts and the 6% overhead theohwk's run showed over the theoretical 8-task figure — SQS polling and batch tail, not throttling.

**Worst case is now 3 controls, not 4** — daily is not evaluated — so the ceiling falls from $0.057 to **$0.043 per player**, and the 10,000-player abuse ceiling from ~$572 to **~$430**. Every latency and cost figure elsewhere in this file that still assumes 55.6 s/game is **conservative by ~44%**.

### The existing data

- [x] **~390 months with no PGNs and no evals** — **resolved by deletion, 30 Aug 2026.** The table was wiped: 147,214 games and 401 month items, verified empty two ways. Neither option in the old plan was taken — clearing ETags to re-fetch, or leaving them counted-only — because both existed to rescue data written before PGN storage. Deleting it removes the legacy shape entirely, so whatever is re-ingested arrives current from the first write. The cost is real and is ingestion, not money: re-fetching runs through the pinned serialised worker at hours of wall clock. PITR was left as the only floor, deliberately, with no backup taken.
- [x] **`COMPLETE` stops changing meaning — because evaluation state is *derived*, not stored.** It meant *plumbing ran*, then *counted*, and the pressure was to make it mean *evaluated* too. Instead `status` keeps the ingestion meaning it already had and the month item says nothing about evals: `player.py`'s `evaluation_state()` runs the same projected query `analyse.py` already uses to decide what to queue, and returns `evaluated` / `outstanding` / `inScope` / `excluded`.

  **Both stored options were worse.** More `status` values would drop months out of `cumulative()`, which filters on `== "COMPLETE"` — breaking the counted statistics in order to describe the evaluated ones. A counter on the month would be incremented by up to eight evaluators at once and would violate *the aggregate is recomputed rather than accumulated*, the rule that makes redelivery free and that the DLQ drill relied on. The derived version cannot drift from the game items because it **is** the game items, and it needed no migration across the 393 months that then existed.

  **Verified by agreement, not assertion:** on a theohwk-shaped fixture, `outstanding` exactly equals what a `POST /analyse` would queue and `evaluated` equals what it would skip. The two rules are the same rule.

---

## What must not change

Stated because the temptation to revisit them will be strongest here.

- [x] **Ingestion still takes one message at a time.** `max_capacity = 1` is the upstream guard and is drift-checked. Evaluation scaling is *not* a licence to scale ingestion — the Chess.com constraint is unchanged. The drift check was deliberately **scoped to the worker service** when the evaluator arrived, so a shared assertion could not be loosened for one and silently lost for the other.
- [x] **Idempotency must survive.** The aggregate is recomputed rather than accumulated; the games-then-status ordering replaces the single-write guarantee. Evaluation writes named attributes onto an existing game item with `UpdateItem` and accumulates nothing, so re-running a game overwrites rather than doubles.
- [x] **The ETag path must still short-circuit.** A `304` skips the parse, the aggregate and the write. **Drilled 27 Aug 2026** on theohwk 2020-11, a month with 24 evaluated games: `fetching (conditional)` → `unchanged, skipping` in under a second, `lastCheckHit` flipped to `true` and `checkedAt` advanced while `analysedAt` stayed frozen, all 24 evals intact, and **the eval queue never received a message**. Evaluation is a separate route that never touches the ingestion path, so the 155× saving is untouched.

## Failure paths to drill

Same standard as every prior phase: watched live, not asserted.

- [x] **A game the engine cannot parse** → does not fail the whole month. **Drilled itself**: one of theohwk's 227 games was unparseable. It was marked `evalError` with `evalDepth` set — marked rather than merely skipped, so it is not re-attempted on every future analyse — and the other 226 completed. The batch was unaffected. *(The 31 Aug re-run hit no unparseable game across its 201, and no game in the table carries `evalError` today. Whether the original bad game was daily — and so now excluded — or simply outside the current 201 is **not established**: the wipe removed the marking, so this is unproven either way rather than fixed.)*
- [x] **Engine crash or hang mid-game** → the message returns to the queue, nothing half-written. **Drilled 27 Aug 2026** by `stop-task` on a working evaluator with 24 games in flight. SIGTERM → `done` on the game in hand **4 seconds later** → `exiting cleanly`; the rest of that task's batch stayed invisible and was redelivered. ECS replaced the task (7→8), and **24/24 games finished with an empty DLQ**.
- [x] **A job that times out** — solved by shrinking the job rather than growing the timeout. One message per game took the visibility timeout from **7 hours to 5 minutes** against ~45 seconds of work. A per-player message would have needed a timeout longer than most drills.
- [x] **Re-submitting an evaluated month** → the ETag still short-circuits and nothing is re-evaluated. Same drill as the ETag row above.
- [x] **Crash mid-evaluation** → recovery does not double-count. **Drilled** by redriving the eval DLQ: all 10 messages logged `already evaluated` and were deleted without re-running the engine. `acpl` and `blunders` were unchanged and **`evaluatedAt` still held the original timestamps** — the guard short-circuits before any write, so redelivery costs one `GetItem`.
- [x] **Two analyses of the same player at once** → **drilled by accident, and it failed.** A second `POST /analyse` 30 seconds into theohwk's run re-queued all 201 games and spent a second token, because selection filters on `evalDepth` and an in-flight game is not stamped until the engine finishes it. **402 messages for 201 games; 166 duplicates absorbed for a `GetItem` each, but 17 games evaluated twice.** Idempotency held — identical values overwritten, nothing doubled — so the cost was ~9 min of vCPU, ~$0.002. Fixed by the per-player claim; **the fix itself is deployed but not yet drilled live**, because theohwk is now fully evaluated and never reaches the claim.
- [x] ~~**An unverified user submitting two analyses**~~ → **moot.** Verification was cut, so there is no unverified state to drill. The replacement control is the rate limit, **now built** — a token bucket per account, plus the in-flight claim that keeps a duplicate request free.
- [x] **A month that exceeds the item limit** → **no equivalent cliff.** The worst real game is 8,872 B of PGN plus ~500 plies of evals — comfortably inside 400 KB, and a game cannot grow without bound the way a month could. The month item now holds counts only, so the thing that was at 95% is at 0.5 RCUs.

## Cost controls

- [x] **Scale-to-zero is load-bearing twice over now.** Ten idle evaluation tasks at 1 vCPU / 2 GB are **$3.61/day — $108/month** against a ~$2 budget. `check-drift.sh` asserts `MinCapacity == 0` per service and covers the new one automatically. **It very nearly was not enough** — see the Spot quota deadlock below.
- [x] **Re-run end to end on a clean table, 31 Aug 2026.** theohwk re-ingested through the browser (22 months, 1,502 games) and analysed: **201 games evaluated in 13.9 min on 8 tasks**, zero errors, **DLQ empty throughout**. First real-data proof of everything built this phase — the derived counts (201 in scope, 26 daily excluded, matching selection exactly), the daily exclusion, the token bucket, and the 25s player timeout (**1.58 s actual** against 22 months). The engine's output on a real player: **mean ACPL 72.8, 1.94 blunders/game**, plausible for the 352–1304 rating range shown.
- [x] **Verify the parallel speed-up rather than assuming it.** **Measured from the logs:** 190 games across 8 tasks in 14.8 min wall clock, median **31.4 s/game**, giving **6.72× speed-up at 84% parallel efficiency**. Spot contention is real but small — the 16% is SQS polling and batch tail, not throttling. Two corrections fall out: games are **31.4 s, not the 55.6 s** this file assumed, so every cost and latency figure here is **conservative by ~44%**; and the constraint above it is **the account's Fargate Spot quota of 8 vCPUs, not 10**. Asking for 10 does not give you 8 — ECS retries the two unplaceable tasks forever, the scaling activity stays `InProgress`, and Auto Scaling will not begin a scale-*in* while one is unresolved. The service deadlocked at 8 tasks with an empty queue and the scale-in alarm correctly in ALARM but unable to act. `eval_max_tasks` is now **8**, matching the quota: above it the ceiling is not a ceiling, it is a deadlock.
- [x] Workers back to zero after every drill. Verified after the theohwk run: both services desired 0 / running 0, zero tasks in the cluster.
- [x] Re-run `scripts/check-drift.sh` after each apply. Clean after the quota fix.

---

## Deviations from the roadmap

Earlier phases' deviations are in their own files and still stand.

| Deviation | Skill says | We did | Why |
|---|---|---|---|
| *(none yet)* | | | |

## Decision log

Earlier decisions are in [PHASE-1.md](PHASE-1.md), [PHASE-2.md](PHASE-2.md), [PHASE-3.md](PHASE-3.md) and [PHASE-F.md](PHASE-F.md), and remain binding.

| Decision | Chosen | Rejected | Why |
|---|---|---|---|
| Where evaluations live | **One item per game** — `SK = GAME#<yyyy-mm>#<id>`, evals on the item, projected away for list reads | Evals in S3 with a DynamoDB pointer; a compressed blob on the month item; storing only classified moves; raising the limit | Per-ply evals cannot share the month item under any encoding — 975 KB against a 400 KB limit, measured. Per-game items are 906 B, 0.2% of the limit, and the shape matches what the data is: a game is the unit being evaluated. It also fixed a live problem the engine did not create. S3 was the close second and genuinely cheap, but splits one write across two stores and leaves the 95% item untouched. Raising the limit is impossible at any price — 400 KB is a fixed service characteristic, not an adjustable quota. |
| Fetch vs analyse | Two operations, separate limits — `POST /games` ingests, `POST /analyse` evaluates | One submit that both fetches and evaluates; a per-user monthly quota; verified-users-only | Evaluation is ~1,000× the cost of ingestion per game, so they cannot share a limit. Splitting keeps the free half genuinely useful — the counted statistics need no engine — so a new visitor sees a real dashboard rather than a locked door. A quota bounds spend but not concurrency; verified-only bounds both and kills casual use. *(The verification half of this row was later cut outright — see the verification row below. The split itself stands.)* |
| PGN storage | Store the PGN on the game item at ingestion | Re-fetch the game from Chess.com when it is analysed | Re-fetching puts evaluation back behind the serialised worker pin, which is the whole thing the split exists to escape. Storing costs 0.8% of an item and $0.12/month for everything ingested today — and it is the reason evaluation can scale at all. |
| Evaluation concurrency | Its own queue and service, scaled past one task | Reuse the ingestion worker and its pin | The pin protects Chess.com, and evaluation makes zero upstream requests. Concurrency buys latency at no extra cost, because Fargate bills per vCPU-second. |
| Analysis depth | **18**, matching Chess.com's Platinum tier | Depth 8; depth 12; a two-pass depth-8-screen-then-deep design | Measured over 1,047 plies against depth 18: depth 8 recalls **53%** of blunders and reports **half** the true average centipawn loss; depth 12 reaches 65%. A cheap statistic nobody can trust is not a saving. Depth 8 also *invents* mistakes — 46% of its flags are not mistakes at 18 — and telling a user they blundered when they did not is worse than silence. |
| What gets evaluated | **The last 100 games per time control** | Every game; last 100 overall; recent months only | Bounding the games rather than the depth is what makes depth 18 affordable — worst case 400 games, **$0.093** per player, against $0.70 for every game. Per control rather than overall because a player's last 100 games can be entirely one control: theohwk's would be nearly all rapid, hiding 437 blitz games. It also makes the outlier problem disappear — danielnaroditsky's 129,391 games become 318, the same as everyone. |
| Message granularity | **One message per game** | One message per player, the worker selecting games itself | A per-player message pins the whole job to a single task however many are running — measured at ~170 minutes for theohwk's 227 games with a second evaluator sitting idle beside it. Per game, the same job is ~17 minutes on ten workers. It also shortens every failure: the visibility timeout drops from 7 hours to 5 minutes, a crash loses one game rather than a player, and a retry costs 45 seconds instead of hours. Selection moves to the analyse Lambda, which is the right place anyway — it is a question about the table, answered once rather than by every worker. |
| Evaluator ceiling | **8 tasks**, matching the Fargate Spot vCPU quota | 10, the number the cost arithmetic used; raising the quota | Above the quota the ceiling is not a ceiling, it is a **deadlock**: ECS retries unplaceable tasks forever, the scaling activity stays `InProgress`, and Auto Scaling refuses to scale *in* while one is unresolved — so 8 tasks ran indefinitely against an empty queue with the scale-in alarm correctly in ALARM. Raising the quota is possible but adds a request-and-wait to a project whose whole cost story is scale-to-zero, and 8 is within a task or two of 10 anyway. |
| Recording evaluation state | **Derived on read** from the game items — `status` keeps its ingestion meaning and the month says nothing about evals | More `status` values (`COUNTED`/`EVALUATED`); a counter on the month item; a stored flag backfilled across 393 months | The truth already existed and was already queried cheaply — `analyse.py` derives exactly this to decide what to queue, so storing it would denormalise a fact that is one projected Query away. More status values would drop months out of `cumulative()`, which filters on `== "COMPLETE"`, breaking the *counted* statistics to describe the *evaluated* ones. A counter would be incremented by up to eight evaluators at once and would break *the aggregate is recomputed rather than accumulated* — the rule the DLQ-redrive drill depends on. Derived cannot drift, and needed no migration. The cost is one extra Query per player page, which is the thing to measure if the dashboard ever loads it hot. |
| Daily games | **Not evaluated** — `EVAL_CLASSES` is `bullet,blitz,rapid` | Evaluating every control; evaluating daily at a lower depth | A correspondence player moves with an engine and an opening database open, so centipawn loss there measures their **tools, not their judgement** — averaging it into a headline figure makes one number describe two different activities. Excluded *before* the per-class cap, so dropping daily does not consume a slot a blitz game could have used, and reported as its own count rather than folded into `skipped`: skipped games **are** evaluated, excluded games never will be. Also cheaper — worst case falls from 4 controls to 3. |
| The existing 147k games | **Deleted outright**, 30 Aug 2026 | Clearing ETags and re-fetching; leaving them counted-only; stripping eval attributes and keeping the PGNs | Both surviving options existed to rescue data written before PGN storage, and the legacy shape was the thing making them necessary. Deleting removes it, so whatever is re-ingested is current from the first write. The price is paid in **ingestion, not money**: re-fetching runs through the pinned serialised worker, which is hours of wall clock and the one path where the Chess.com constraint still bites. PITR left as the only floor, no backup taken. |
| In-flight duplicate analyse | **One claim item per player**, expiring after 20 min | A marker stamped on each of the 201 selected games; a conditional write at evaluation start in the worker; accepting the duplicates | Selection's dedup only sees *finished* games, so the length of a run is a window where every queued game still looks unevaluated — measured at 402 messages for 201 games, **17 evaluated twice**. Per-game markers mean 201 writes on a read-only route plus `BatchWriteItem`, an action this project has been caught missing twice. A worker-side conditional write fixes the deeper race but costs an extra write per game on the hot path, for damage measured at ~$0.002 with idempotency holding. The claim closes the door the duplicates came through, which in practice closes both. |
| Rate limit shape | **Token bucket per account** — 5 tokens, one back per hour, charged only when a request queues real work | A flat 1 player/hour; a fixed hourly counter; API Gateway usage plans; a WAF rate rule; a per-IP limit | The existing 10 req/s stage throttle is the wrong *unit* and the wrong *scope*: ~300 requests well under 10/s queue ~300 distinct players, and the throttle is account-wide rather than per-user. A flat 1/hour bounds cost correctly but makes the product — comparing players — a three-hour job for three players; the bucket converges to the same sustained rate while keeping first use normal. Usage plans are REST-API-only and this is an HTTP API. WAF is ~$5/month against a ~$2 budget, and keys on IP rather than account. |
| Account verification | **Cut** — a registered account and a rate limit | Profile-token verification gating bulk analysis; Chess.com OAuth; Lichess link as proof | Verification existed to stop one user running up unbounded cost. With a hard per-player cap and per-game dedup there is no unbounded cost: re-submitting an analysed player is **$0.00**, and analysis is keyed by player rather than user, so a popular player is paid for once by whoever asks first. The residual risk is scripted distinct usernames, which a rate limit handles — and one was already owed to Phase F, so it is one control serving two purposes rather than a new feature. |

---

## Watch for

- **The engine does not license more ingestion concurrency.** Evaluation scaling is safe *because it makes no upstream requests*. Ingestion's constraint is unchanged and is still the one risk money cannot undo.
- **Depth was the wrong lever, and measuring is what showed it.** Depth 8 was chosen on cost and plausible reasoning, and benchmarking found 53% blunder recall and a headline centipawn figure off by half. The fix was bounding the *games* rather than the depth. Reasoning about engine behaviour without measuring it produced a confidently wrong answer here.
- **Idle evaluation workers are the new worst cost mistake.** $108/month against a ~$2 budget — 30× worse than the ingestion worker ever was. And the way it nearly happened was *raising* a ceiling, not lowering one.
- **A ceiling above a service quota is a deadlock, not a ceiling.** `max_capacity` past the Fargate Spot vCPU quota leaves tasks permanently unplaceable, the scaling activity permanently `InProgress`, and scale-in permanently blocked. Every component reported success throughout — the run finished, the queue emptied, the alarm fired correctly — and the tasks stayed up. **Check the quota before raising any ceiling.**
- **Four bugs this phase hid behind healthy status.** The mate-score contamination, the scale-in alarm watching only `Visible`, the execution role scoped to one log group, and the quota deadlock. Each one had everything reporting green. "No errors" is not evidence.
- **A timeout inherited from a sibling stops being right when the work changes.** The player route sat on `lambda_timeout`, whose own description says it is sized for "one DynamoDB call" — accurate when written, and quietly wrong the moment the route began paginating a second Query across a player's whole game partition. The comment is what caught it, not a failure. Shared config is an assumption with a shelf life.
- **Deriving beat storing, and the tell was that the query already existed.** The month item could not say whether it was counted or evaluated, and both instincts — a new status value, a counter — would have broken something already working. The answer was that `analyse.py` already computed the fact to decide what to queue. **Before adding a field, check whether something already derives it.**
- **The rate limit bounds an account, and accounts are free.** It makes casual abuse impossible and determined abuse slow and visible — it is not a cap on spend. The budget alarm is still the only thing that actually stops the money. Do not let the presence of a limit read as "spend is solved".
- **A rate limit that charges for free work breaks the thing it protects.** Re-submitting an analysed player is $0.00 by design, and that property is what let verification be cut. Debiting the bucket before selection would have quietly undone it — the limit has to be charged on work found, not on requests made.
- **Storage recurs where compute does not.** PGNs bill monthly whether or not anyone analyses them.
- **"COMPLETE" changes meaning again**, for the third time. The item has to say which meaning applies.
- **Fixed by a per-player claim** — `SK = ANALYSE#claim`, written after selection and before the token is charged, expiring after `ANALYSE_CLAIM_SECONDS` (1200). A second `/analyse` inside the window returns 202 with `queued: 0` and `alreadyQueued`, spending no token. One item rather than a marker on each of 201 games, which would have made a read-only front door into a bulk writer needing `BatchWriteItem`. It **expires rather than being cleared**, so a crashed run cannot wedge a player — and the condition treats an expired-but-unswept item as absent, because DynamoDB's TTL sweep runs hours late. Claimed *before* charging, and **released if the token check then fails**, so a rate-limited request does not lock the player out for 20 minutes having done nothing. The cost accepted: a legitimate second request for genuinely new games also waits out the window.
- **The dedup guard only holds once a game has *finished*.** Drilled 31 Aug 2026: a second `POST /analyse` while the first was still running re-queued all 201 games, because selection filters on `evalDepth == DEPTH` and an in-flight game has not been stamped yet. Of the 201 duplicates, **166 were absorbed for a `GetItem`** as designed — but **17 games were evaluated twice**, the duplicate arriving while the original was mid-engine so both `GetItem` checks saw unevaluated. "A duplicate delivery costs a `GetItem` rather than 45 seconds of engine" is therefore true only *after* the first pass completes; under concurrency it can cost a full evaluation. ~9 min of wasted vCPU, ~$0.002 — harmless in itself, and **idempotency held**: the re-run overwrote identical values rather than doubling, exactly as the named-attribute `UpdateItem` design promises. The gap is a front-door claim, not a worker bug.
- **A DLQ message is not proof of lost work.** Both games in the eval DLQ had been **successfully evaluated** — they exhausted `maxReceiveCount` during the AccessDenied window and then succeeded on a later delivery, leaving the failure record behind but not the failure. Read the *table* before concluding from the queue.
- **`aws logs` needs `MSYS_NO_PATHCONV=1` in Git Bash on Windows.** A log group name starting with `/` is rewritten into a Windows path before the SDK sees it, and the error blames the *parameter* — `failed to satisfy constraint... Member must satisfy regular expression pattern` — on a name that is plainly valid. Nothing about the message points at the shell. Same class of trap as the `filter-log-events` note below: the tooling lied about why.
- **`ApproximateNumberOfMessages` goes stale under active consumption.** During the theohwk evaluation it sat at 322 across three consecutive samples while in-flight fell 80 → 74 → 56 and the table showed 27 games finished. Nothing was wrong. **Read the table for progress**; the queue metric is for scaling decisions, and even then it is approximate.
- **`filter-log-events` silently returned nothing** where `get-log-events` returned 622 lines. Every drill here was verified by reading streams directly. A log query that comes back empty is not evidence of a quiet system.
- **The dashboard is the product, not the single-game view.** The skill says Lichess does the single-game report better, and it is the tempting place to over-invest.
