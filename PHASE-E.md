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

**Per-ply evaluations do not fit the current item, and this is not close.** Measured against the numbers already established in Phase 3:

| | |
|---|---|
| Heaviest month sampled | 828 games |
| Plies at ~80/game | 66,240 |
| At 8 bytes per eval | **518 KB** |
| DynamoDB item limit | **400 KB** |
| Already used by summary rows | 145 KB (36%) |

So the evals alone exceed the limit before the existing rows are counted. Roughly **408 of 828 games** would fit in the remaining headroom. Phase 3 wrote down "full move data is Phase 4's problem, under Phase 4's storage decision" — this is that decision, and it has to be made before any engine code is written, because it determines what the worker writes.

- [ ] **Decide where evaluations live.** The options and what each costs are in the storage section below. Nothing else in this phase can start until this is settled.

## Storage — the options

**Not yet chosen.** Presented so the trade-offs are visible; the decision is the owner's.

| Option | Shape | Cost |
|---|---|---|
| **One item per game** | `PK = PLAYER#…`, `SK = GAME#<id>`, evals as a list on the game item | Natural fit — a game is the unit being evaluated. A month becomes a Query rather than a GetItem, so the month read changes shape. 828 items per heavy month. |
| **Compress the evals** | Store per-ply evals as a packed binary blob on the existing item | Keeps one item per month. A 2-byte int per ply is 130KB for a heavy month — fits, but only just, and it is opaque to anything but our own code. |
| **S3 for evals** | Evals as an object per month, DynamoDB holds a pointer | No size ceiling, cheap at rest. Adds S3 to a project that deliberately has none, and a second read to render a page. |
| **Sample rather than store every ply** | Store only classified moves (blunders, mistakes, turning points) | The dashboard needs blunders and centipawn loss, not every eval. Far smaller. The eval *graph* would need the full series, so this trades a feature for simplicity. |

**Worth noting before choosing:** the skill's product spec lists the eval graph as part of the single-game report, and calls the single-game view "a supporting screen — build the thinnest version that works, because Lichess already does it better". The aggregate dashboard is the product. That argues for storing what the *dashboard* needs and treating the full eval series as optional.

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
| *(none yet — the storage decision is first)* | | | |

---

## Watch for

- **The storage decision comes first.** Writing engine code before knowing where evals live means writing it twice.
- **Depth is the cost lever, and it is multiplicative.** Every increment applies to every ply of every game of every player. A default chosen without measuring is a bill chosen without measuring.
- **The engine does not license more concurrency.** Slower per-month work makes scaling out tempting; the Chess.com constraint is unchanged and is still the one risk money cannot undo.
- **"COMPLETE" changes meaning again.** It meant *plumbing ran*, then *counted*. It will now need to distinguish counted from evaluated, and the item has to say which — the same care Phase 3 took when the word first changed.
- **The dashboard is the product, not the single-game view.** The skill says Lichess does the single-game report better and it is the tempting place to over-invest.
