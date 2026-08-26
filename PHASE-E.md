# Phase E — Stockfish

**Goal:** make "analysed" mean *evaluated*. Phase 3 made it mean *counted* — games, W/D/L, colours, time controls, ratings — which is a real aggregate a dashboard can render, and which deliberately shipped without an engine. This phase adds the engine that makes this a chess project rather than an ingestion pipeline.

**This is the phase the roadmap never scheduled.** The numbered phases map to certifications — 3 is ingestion, 6 is VPC, 4 is observability, 5 is CI/CD, 7 is load and cost — and none of them is "add Stockfish". The plan said "Phase 1 uses a fake worker… then swap the engine in" and never named when. Named explicitly as **Phase E**, after **Phase F** because the engine's output is visual: eval graphs, annotated moves, blunders by phase. Building it before anything can display it makes it hard to judge whether the analysis is any good.

Phases 1–3 are complete ([PHASE-1.md](PHASE-1.md), [PHASE-2.md](PHASE-2.md), [CLAUDE.md](CLAUDE.md)); Phase F is complete except hosting, which is blocked on choosing a domain. Read them for decisions already made, and do not redo them.

Account: `961868442307` · Region: `ap-southeast-1` · IAM user: `terraform-admin` (MFA enabled)

---

## How we work on this

Unchanged from Phases 1–F, and still the point. **Claude writes the code. I make the decisions, after I understand them.**

- **Explain first, then write.** What problem it solves in *this* app, what breaks without it, what it costs. Then I decide.
- **Ask, don't assume.** Any choice with a real trade-off is mine.
- **Name the failure mode** a service exists to handle here. "Real systems use it" gets it cut — that rule cut S3 in Phase 3 and the automated spending stop in Phase F.
- **Tick items off in this file as they are completed.**
- **Record decisions in the log below** — choice, alternative, reason.
- **Say when I am wrong, and why.**

Run `bash scripts/check-drift.sh` after every apply.

---

## The decision that comes before the engine

**Per-ply evaluations do not fit the current item, and this is not close.** Measured live in August 2026 — Phase 3's own figures turned out to be conservative in both directions, so these replace them:

| | |
|---|---|
| Heaviest month | danielnaroditsky 2024-03 — **2,815 games** (Phase 3 sampled 828) |
| Mean plies per game | **177** (an early estimate of 80 was less than half) |
| Plies in that month | **499,444** |
| Evals at 2 B/ply | **975 KB** — 2.4× the whole limit |
| DynamoDB item limit | **400 KB**, fixed and not adjustable |
| That month's item **today** | **~380 KB — 95% of the limit**, game rows alone |

Evals exceed the entire limit before the existing rows are counted, so they cannot share the month item under any encoding. Phase 3 wrote "full move data is Phase 4's problem, under Phase 4's storage decision" — this is that decision, and it comes before any engine code because it determines what the worker writes.

**It is also more urgent than a planning item.** That 95% is true now, with no engine involved: the heaviest month is one growth spurt from failing to write, and Phase 3 has no failure path for an oversized item.

- [x] **Decided: one item per game.** `SK = GAME#<yyyy-mm>#<id>`, evals on the game item. Chosen over S3, compression and storing only classified moves — see the storage section and the decision log.
- [x] **Built and migrated, 26 Aug 2026** — before any engine work, because the limit was already being approached without one. **393 months, 147,214 games, zero sort-key collisions.** The item that was at 95% of the limit (`danielnaroditsky/2024-03`) now reads at **0.5 RCUs instead of 47.5** — under 4KB where it was ~380KB. All routes verified against live data afterwards: the heaviest month returns all 2,815 games, and every player's month and game counts are unchanged.
  - **Reads tolerate both shapes**, which is what let the migration run as a background job rather than a flag day: the inline array wins when present, otherwise a paginated Query. Migrating one small player first proved it end to end.
  - **Sequencing mistake worth recording:** the first player was migrated *before* the reader that understands the new shape was deployed, so its games briefly read as zero. The compatibility design meant it recovered the moment the handler shipped, but the correct order is reader first, then data.
  - **The worker's write path proven end to end, 26 Aug 2026.** Forced `theohwk/2026-03` to FAILED with its ETag cleared, re-submitted (1 queued, 21 skipped — dedup intact), and watched it through. Result: `COMPLETE`, **no inline array**, 47 game items, a fresh ETag, and the route reading all 47 back.
  - **It failed first, and failed correctly.** The worker lacked `dynamodb:BatchWriteItem` and `Query` — a fourth bug in the same family, and `BatchWriteItem` is a distinct action rather than a variant of `PutItem`, exactly as `SendMessageBatch` was in Phase 3. The message retried three times and reached the DLQ. **The month stayed `PENDING` throughout rather than showing a false `COMPLETE`** — the games-first-then-status ordering doing the job it was designed for, observed under a real failure rather than argued. Redriven after the IAM fix; DLQ back to empty, `check-drift.sh` clean.
  - **Four bugs only deploying could find**, the same pattern Phase 3 recorded. `status` lacked `dynamodb:Query` — it had `GetItem` only. The directory `Scan` counted game items as months, which would have turned 149 months into 129,391; it needed a `FilterExpression` it never had, because a Scan sees every item in the table. And the IAM fix appeared not to work: `simulate-principal-policy` said *allowed* while the function kept returning AccessDenied, because the Lambda's **cached execution environment was holding pre-change credentials**. Forcing new containers fixed it — an IAM fix can look wrong when it is only stale.

## Storage — one item per game

**Decided.** The month item keeps its status, ETag and summary; each game becomes its own item carrying its own evals.

```
PK  PLAYER#chesscom#erik
SK  ARCHIVE#2026-08              <- ~400 B: status, etag, checkedAt, summary
                                    (no games array)

PK  PLAYER#chesscom#erik
SK  GAME#2026-08#996120144       <- ~906 B: the existing row + evals + acpl
                                    + blunders
```

**Measured, not estimated.** Everything below is from the live API and the deployed table, August 2026.

| | |
|---|---|
| Mean plies per game | **177** (median 167, max 557) |
| Heaviest month | danielnaroditsky 2024-03 — **2,815 games, 499,444 plies**, 11.3 MB raw |
| Per-game item | **906 B** = 138 B row + 177 evals × 4 B + 60 B keys |
| That as a share of the item limit | **0.2%** |
| Longest single game (557 plies) | 2.4 KB |

**The ceiling stops being a design constraint.** The heaviest month becomes 2,490 KB spread over 2,815 items, none near the limit — instead of 380 KB crammed into one.

**This fixes a problem that already exists.** `danielnaroditsky/2024-03` is at **~380 KB of the 400 KB limit today** — 95%, with no engine involved, measured as 47.5 RCUs on a GetItem. Phase 3 recorded a ceiling of "~2,288 games per month" from an estimate of 179 B/game; the real encoding is 138 B/game, so the ceiling arrived later than predicted but this month is already past the stated one. **A month roughly 5% heavier fails on write, and Phase 3 has no failure path for it** — it would surface as a generic worker error, retry three times, and land in the DLQ looking exactly like a Chess.com outage. See the failure paths below.

**What it costs:**

- **The month read becomes a Query.** `PK = PLAYER#… AND begins_with(SK, "GAME#<yyyy-mm>#")` — which is why the archive goes *in* the sort key, keeping a month contiguous. At 2,815 × 906 B that is 2.5 MB, over the **1 MB Query cap**, so it needs pagination. The same fix the player route already carries, and the same limit that silently truncated it in Phase 3.
- **The write becomes many.** One `UpdateItem` becomes ~113 `BatchWriteItem` calls, and **Phase 3's atomicity argument does not survive unchanged**: today games, aggregate, ETag and status land in a single item write, so `COMPLETE` is never visible without its data. Across 2,816 items it can be. Preserved by *ordering* instead — write every game item first, flip the month to `COMPLETE` last — so a crash leaves the month not-COMPLETE and the message replays. That is the property to re-drill, not to assume.
- **Evals ride on the game item and are projected away for list reads.** Keeping them on the item avoids a second read for the eval graph; a `ProjectionExpression` stops the games *list* dragging 177 numbers per game across the wire. Exactly the trick that made the player route 4x faster in Phase 3.

**The ETag layer is untouched.** It stays on the month item, so a `304` still short-circuits before any game write happens.

**Rejected:**

| Option | Why not |
|---|---|
| **Evals in S3**, pointer in DynamoDB | Genuinely cheap — 16 MB gzipped for a 129,391-game player, **$0.0004/month**. But it splits one write across two stores, so the pointer and the object can disagree, and Phase 3's "no window where COMPLETE is visible without its data" would need re-arguing against a harder version of the problem. It also leaves the 95%-full month item exactly as it is. Worth revisiting only if per-ply data outgrows what a game item can hold. |
| **Compress evals** into a packed blob on the month item | Keeps one item, but a heavy month is 975 KB of evals at 2 B/ply — **2.4× the entire limit** before the existing rows. Does not fit under any encoding, so this is not a close call. |
| **Store only classified moves** (blunders, mistakes, turning points) | ~20x smaller and probably enough for the dashboard, which is the actual product. Cut because it trades away the eval graph permanently, and per-game items make the full series affordable anyway. Still the fallback if evaluation cost forces a retreat. |
| **Raise the item limit** | Not possible at any price. 400 KB is a fixed service characteristic, not a quota — it does not appear in Service Quotas and has no support path. Confirmed against the API. |

## The engine

- [ ] **Stockfish in the image.** The Dockerfile already anticipates this and says the image "stays this shape" — an apt or copy layer. Confirm licence terms (GPL) are compatible with how this is deployed.
- [ ] **One engine process, reused.** The skill's stated reason for Fargate over Lambda is "warm engine process between games". Starting Stockfish per game would throw that away.
- [ ] **Decide the analysis depth or time budget per move.** This is the single biggest cost lever in the phase — it multiplies by every ply of every game of every month. Not a detail to leave to a default.
- [ ] **Decide what happens to already-COMPLETE months.** 500+ months are ingested and counted but not evaluated. Re-evaluating them is the expensive pass; a `COMPLETE` month that has no evals is a *different* state from one that does, and the item needs to say which.
- [ ] **Decide whether every game is evaluated.** A player with 129,391 games is not a hypothetical — danielnaroditsky is already in the table. Evaluating all of them at any depth is the dominant cost of this project.

## Task sizing — the cost model changes here

**Ingestion is I/O-bound; Stockfish is CPU-bound.** The worker runs on 0.25 vCPU / 0.5 GB, which is sized for waiting on HTTP. The skill flags this explicitly: task sizing gets revisited here, and it changes the per-unit costs and the idle figure together.

- [ ] **Re-measure the per-month cost** with the engine in the loop. Phase 3's figures ($0.000186 per month, $0.028 for a whole player) are ingestion-only and will not survive.
- [ ] **Re-check the idle figure.** The skill notes the ~$44/month figure applies at 1 vCPU / 2GB — which is roughly what Stockfish will want. The current ~$12/month (and less on Spot) is a 0.25 vCPU number.
- [ ] **Confirm scale-to-zero still holds.** It is the argument that makes idle cost irrelevant, and it matters more at a larger task size, not less.

## What does not change

Stated because the temptation to revisit them will be strongest here.

- [ ] **The worker still takes one message at a time.** `max_capacity = 1` is the upstream guard and is now drift-checked. A slower worker makes "scale it out" more tempting, and the Chess.com constraint has not changed. Evaluating is CPU-bound and local — it is not a reason to make more concurrent requests upstream.
- [ ] **Idempotency must survive.** The Phase 3 argument is that the aggregate is recomputed from the archive rather than accumulated, and that everything lands in a single `UpdateItem`. Evaluations must not break either half — in particular, a partially-evaluated month must not be visible as `COMPLETE`.
- [ ] **The ETag path must still short-circuit.** A `304` currently skips the parse, the aggregate and the write. If evaluation is added naively, an unchanged month could be re-evaluated at full cost — turning the 155x saving into nothing.

## Failure paths to drill

Same standard as every prior phase: watched live, not asserted.

- [ ] **A game the engine cannot parse** → does not fail the whole month.
- [ ] **Engine crash or hang mid-month** → the message returns to the queue and the month is not left half-written.
- [ ] **A month that times out** — evaluation is far slower than ingestion, so the visibility timeout that was ample for a fetch may not be.
- [ ] **Re-submitting an evaluated month** → the ETag still short-circuits and nothing is re-evaluated.
- [ ] **Crash mid-evaluation** → recovery does not double-count, same standard as the Phase 3 drill.
- [ ] **A month that exceeds the item limit** → the failure Phase 3 has no path for. Fixed by per-game items, but drill it: the pre-migration behaviour is a generic write error retrying into the DLQ, indistinguishable from an upstream outage. Confirm the new shape has no equivalent cliff.

## Cost controls

- [ ] Worker back to zero tasks after every drill. This matters *more* at a larger task size.
- [ ] Re-run `scripts/check-drift.sh` after each apply.
- [ ] **Decide the ceiling before building.** Evaluating every ply of every game of every player is unbounded work against a ~$2/month budget. The cap belongs in the design, not in a later panic.

---

## Deviations from the roadmap

| Deviation | Skill says | We did | Why |
|---|---|---|---|
| *(none yet)* | | | |

**One inconsistency in the skill to fix on the next update:** the architecture section still says "Stockfish lands here in Phase 4", contradicting the Phase E section in the same document, which calls naming it Phase 4 "wrong twice over". A leftover from the Phase 3 rewrite.

## Decision log

| Decision | Chosen | Rejected | Why |
|---|---|---|---|
| Where evaluations live | **One item per game** — `SK = GAME#<yyyy-mm>#<id>`, evals on the item, projected away for list reads | Evals in S3 with a DynamoDB pointer; a compressed blob on the month item; storing only classified moves; raising the limit | Per-ply evals cannot share the month item under any encoding — 975 KB against a 400 KB limit for the heaviest month, measured. Per-game items are 906 B, 0.2% of the limit, and the shape matches what the data actually is: a game is the unit being evaluated. It also fixes a live problem the engine did not create — that heaviest month is already at 95% of the limit with game rows alone. S3 was the close second and is genuinely cheap, but it splits one write across two stores and leaves the 95% item untouched. Raising the limit is not an option at any price: 400 KB is a fixed service characteristic, not an adjustable quota. |

---

## Watch for

- **The storage decision comes first.** Writing engine code before knowing where evals live means writing it twice.
- **Depth is the cost lever, and it is multiplicative.** Every increment applies to every ply of every game of every player. A default chosen without measuring is a bill chosen without measuring.
- **The engine does not license more concurrency.** Slower per-month work makes scaling out tempting; the Chess.com constraint is unchanged and is still the one risk money cannot undo.
- **"COMPLETE" changes meaning again.** It meant *plumbing ran*, then *counted*. It will now need to distinguish counted from evaluated, and the item has to say which — the same care Phase 3 took when the word first changed.
- **The dashboard is the product, not the single-game view.** The skill says Lichess does the single-game report better and it is the tempting place to over-invest.
