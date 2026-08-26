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

- [x] **Migrated 26 Aug 2026** — 393 months, **147,214 games**, zero sort-key collisions. That item now reads at **0.5 RCUs instead of 47.5**. All routes verified afterwards; every player's month and game counts unchanged.
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
| Unverified user | Unrestricted | **One game at a time** |
| Verified user | Unrestricted | Bulk |

**The basic statistics are always shown.** Everything Phase 3 built needs no engine and stays open to everyone; evaluation statistics are a *second* group on the page, populated only for games actually analysed. An unverified visitor gets a real dashboard rather than a locked door — a better split than the model it borrows from, which gates its only product.

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

**Concurrency buys latency, not cost** — Fargate bills per vCPU-second. Measured on Stockfish 17 at 0.25 vCPU, depth 8, scaled to the project mean of 177 plies:

| | 1 worker | 10 workers | Cost |
|---|---|---|---|
| theohwk (1,502 games) | 19 min | 2 min | $0.00 |
| erik (16,321) | 3.4 hr | 20 min | $0.05 |
| danielnaroditsky (129,391) | 1.1 days | 2.7 hr | $0.41 |
| **Everything ingested (147,214)** | 31 hr | **3.1 hr** | **$0.46** |

### Every game is evaluated

For verified users, in bulk; unverified users get one game at a time, which bounds the exposure. Cost is ~**$0.01** per typical 3,000-game player at depth 8. **The risk was never a single user but an open door** — at ~200 users the ~$2/month budget breaks, and the verification gate is what closes it.

---

## To build

### Verification

- [ ] **Profile-token verification for Chess.com.** The user pastes a one-time token into their profile `location` field; one call to the public profile endpoint confirms it, the link is marked verified, and they clear the field. Chess.com's OAuth is approval-gated and Phase 2 declined to apply, recording "revisit only if a feature appears that genuinely requires a verified Chess.com link" — **this is that feature**, and the profile-token route needs nobody's approval.
- [ ] **Gate on the existing `verified` flag.** Phase 2 already built `LINK#<platform>` items carrying it, so this is wiring rather than new infrastructure.
- [ ] **Any user may analyse any player.** Verification lifts the concurrency limit; it does not restrict *whose* games may be submitted. Analysis stays public shared data, so a popular player is evaluated once for everyone — itself a real cost saving.

### The engine

- [ ] **Stockfish in the image.** The Dockerfile already anticipates this and says the image "stays this shape" — an apt or copy layer. Confirm the GPL terms are compatible with how this is deployed.
- [ ] **One engine process, reused.** The skill's stated reason for Fargate over Lambda is "warm engine process between games". Starting Stockfish per game throws that away.
- [ ] **Confirm depth 8 actually catches blunders.** Measured at 0.25 vCPU: **depth 8: 17 ms/ply, 10: 49, 12: 139, 15: 395** — 3.0 / 8.7 / 24.5 / 69.8 seconds per game at the project mean. Depth 8 is the working assumption because a blunder is a large eval swing and does not need deep search. **This is a quality question, not a cost one**, and it is the one number here chosen without evidence.
- [ ] **Separate route** for per-game analysis, against an already-ingested game.
- [ ] **Ingestion stores the PGN** on the game item.

### Infrastructure

- [ ] **Separate queue and service** for evaluation, so ingestion stays pinned at 1 and evaluation scales independently.
- [ ] **Task sizing.** Ingestion is I/O-bound on 0.25 vCPU / 0.5 GB; Stockfish is CPU-bound and wants more. Roughly **cost-neutral** — 4× faster at 4× the rate — so this is a latency decision, not a spend one.
- [ ] **Re-measure the per-month cost** with the engine in the loop. Phase 3's $0.000186/month and $0.028/player are ingestion-only and will not survive.

### The existing data

- [ ] **~390 months are `COMPLETE` but have no PGNs and no evals**, and their stored ETags mean a re-submit returns `304` and skips everything. **Solve this first when building** — it determines whether existing data is usable or must be re-fetched.
- [ ] **`COMPLETE` changes meaning again.** It meant *plumbing ran*, then *counted*. It must now distinguish counted from evaluated, and the item has to say which.

---

## What must not change

Stated because the temptation to revisit them will be strongest here.

- [ ] **Ingestion still takes one message at a time.** `max_capacity = 1` is the upstream guard and is drift-checked. Evaluation scaling is *not* a licence to scale ingestion — the Chess.com constraint is unchanged.
- [ ] **Idempotency must survive.** The aggregate is recomputed rather than accumulated; the games-then-status ordering replaces the single-write guarantee. Evaluation must break neither.
- [ ] **The ETag path must still short-circuit.** A `304` skips the parse, the aggregate and the write. Added naively, evaluation could re-run on an unchanged month and turn the 155× saving into nothing.

## Failure paths to drill

Same standard as every prior phase: watched live, not asserted.

- [ ] **A game the engine cannot parse** → does not fail the whole month.
- [ ] **Engine crash or hang mid-game** → the message returns to the queue, nothing half-written.
- [ ] **A job that times out** — evaluation is far slower than ingestion, so a visibility timeout ample for a fetch may not be.
- [ ] **Re-submitting an evaluated month** → the ETag still short-circuits and nothing is re-evaluated.
- [ ] **Crash mid-evaluation** → recovery does not double-count.
- [ ] **An unverified user submitting two analyses** → the second is refused, not queued.
- [ ] **A month that exceeds the item limit** → fixed by per-game items, but confirm the new shape has no equivalent cliff.

## Cost controls

- [ ] **Scale-to-zero is load-bearing twice over now.** Ten idle evaluation tasks at 1 vCPU / 2 GB are **$3.61/day — $108/month** against a ~$2 budget. `check-drift.sh` asserts `MinCapacity == 0` per service, so a new service is covered automatically; **confirm it fires rather than assuming**.
- [ ] **Verify the parallel speed-up rather than assuming it.** The arithmetic assumes ten tasks each get a full vCPU; Spot contention is unmeasured.
- [ ] Workers back to zero after every drill.
- [ ] Re-run `scripts/check-drift.sh` after each apply.

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
| Fetch vs analyse | Two operations, separate limits — bulk analysis needs a verified account, one game at a time otherwise | One submit that both fetches and evaluates; a per-user monthly quota; verified-users-only | Evaluation is ~1,000× the cost of ingestion per game, so they cannot share a limit. Splitting keeps the free half genuinely useful — the counted statistics need no engine — so a new visitor sees a real dashboard rather than a locked door. A quota bounds spend but not concurrency; verified-only bounds both and kills casual use. |
| PGN storage | Store the PGN on the game item at ingestion | Re-fetch the game from Chess.com when it is analysed | Re-fetching puts evaluation back behind the serialised worker pin, which is the whole thing the split exists to escape. Storing costs 0.8% of an item and $0.12/month for everything ingested today — and it is the reason evaluation can scale at all. |
| Evaluation concurrency | Its own queue and service, scaled past one task | Reuse the ingestion worker and its pin | The pin protects Chess.com, and evaluation makes zero upstream requests. Concurrency buys latency at no extra cost, because Fargate bills per vCPU-second. |

---

## Watch for

- **The engine does not license more ingestion concurrency.** Evaluation scaling is safe *because it makes no upstream requests*. Ingestion's constraint is unchanged and is still the one risk money cannot undo.
- **Depth is multiplicative.** Every increment applies to every ply of every game of every player. Depth 8 is chosen on cost and reasoning, not yet on evidence that it catches blunders.
- **Idle evaluation workers are the new worst cost mistake.** $108/month against a ~$2 budget — 30× worse than the ingestion worker ever was.
- **Storage recurs where compute does not.** PGNs bill monthly whether or not anyone analyses them.
- **"COMPLETE" changes meaning again**, for the third time. The item has to say which meaning applies.
- **The dashboard is the product, not the single-game view.** The skill says Lichess does the single-game report better, and it is the tempting place to over-invest.
