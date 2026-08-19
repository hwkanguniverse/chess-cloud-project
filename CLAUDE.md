# Phase 3 — Checklist

**Goal:** make the pipeline carry real data. Phase 1 built the shape and Phase 2 put an identity in front of it, but the worker still sleeps ten seconds and writes `{"fake": true}`. By the end of this phase a submitted player-month fetches real games from Chess.com, and a re-submitted one costs almost nothing because the archive has not changed.

**Still no Stockfish.** The engine is what makes this a chess project; ingestion is what makes it a distributed system. Doing both at once means debugging chess problems and AWS problems simultaneously, which is exactly what Phase 1's fake worker existed to avoid. The worker will fetch, store and count real games — it will not evaluate positions.

Phases 1 and 2 are complete; their checklists are preserved in [PHASE-1.md](PHASE-1.md) and [PHASE-2.md](PHASE-2.md). Read them for decisions already made, and do not redo them.

Account: `961868442307` · Region: `ap-southeast-1` · IAM user: `terraform-admin` (MFA enabled)

---

## How we work on this

Unchanged, and still the point of the exercise. This project is a learning exercise; the deliverable is understanding, not a finished stack — a working stack I cannot explain is a failed phase.

**Claude writes the code. I make the decisions, after I understand them.**

- **Explain first, then write.** Before adding a service: what problem it solves in *this* app, what breaks without it, what it costs. Then I decide, then you write it.
- **Ask, don't assume.** Any choice with a real trade-off — service selection, retry policy, storage layout, what counts as done — is mine. Present the options and what each costs, then wait.
- **Explain the failure mode a service exists to handle** in *this* app before adding it. If the honest answer is "real systems use it," it gets cut.
- **Tick items off in this file as they are completed.** A stale checklist is worse than none.
- **Record decisions in the log below** — choice, alternative, reason. The reasoning is what fades.
- **Say when I am wrong, and why.** Agreeing with a bad call to be pleasant wastes the exercise.
- **Keep this file high level.** Purpose of each service and the decisions behind it. Implementation detail lives in the code, not here.

## Staying faithful to the roadmap

The `aws-cert-plan` skill is the source of truth for architecture and cost decisions. This file is a working checklist derived from it — **it does not override it.** Where they disagree, the skill wins and this file gets fixed.

- **Do not restate the skill's reasoning here** — reference it. Duplicated rationale is what drifts.
- **Re-read the skill at the start of each phase**, and before any decision it already covers. Do not work from memory of it.
- **Any deviation goes in the Deviations table below, with a reason**, or it does not happen.
- **The skill is the constraint list, not a suggestion.** Load-bearing for Phase 3: serialised ingestion per user (parallel requests get 429), one queue message per user-month, ETag/`If-None-Match` for cheap re-analysis, `410` treated as permanent, and a User-Agent carrying contact details.
- **If a constraint turns out to be wrong**, that is a finding — say so, and update the *skill* on the Claude account, not just this file.

*Access note: the skill is not readable from the Claude Code CLI. It is exported as `aws-cert-plan.skill` (a zip containing `SKILL.md`) and unpacked. It was updated at the end of Phase 2 to correct the data model, the Phase 2/3 rows and the architecture section — so the current copy already reflects what this project actually built.*

Run `bash scripts/check-drift.sh` after every apply.

---

## Where things stand

Phase 1 overshot and built most of Phase 3's plumbing. What is genuinely left is the *data*, not the pipeline.

| Skill's Phase 3 | Status | Remaining |
|---|---|---|
| SQS → worker → DLQ | Built, drilled, redrive proven | — |
| Idempotency | Argued and relied on: analysis is deterministic and overwrites the same item | Re-check it once the worker writes real data — the argument was made about a fake result |
| Presigned S3 upload | Not built. No S3 bucket exists in the project at all | **The whole path** — and see the open question below about whether it earns its place yet |
| Archive ingestion + ETag/304 | Not built. The worker sleeps and writes a hardcoded result | **The core of this phase** |

**The key work is already done.** Phase 2 re-keyed analysis to `PLAYER#<platform>#<username>` / `ARCHIVE#<yyyy-mm>` with conditional-insert dedup, which is the shape ingestion needs. That was pulled forward deliberately so this phase lands on the corrected model.

---

## Real ingestion — the core of the phase

**What it is for:** the worker currently proves the plumbing works. This makes it do the job.

Chess.com's Published Data API is public, unauthenticated and explicitly sanctioned. The constraints below are the skill's and are not negotiable without a deviation row.

- [ ] **Fetch a monthly archive** — `GET /pub/player/{username}/games/{yyyy}/{mm}`. One request per queue message, which is what "one message per user-month" already set up.
- [ ] **Send a User-Agent with contact details.** Chess.com tries to reach you before blocking. A missing UA is the difference between an email and an IP ban.
- [ ] **Serialise per user.** Parallel requests may return `429`. This is a real design constraint worth being able to talk about, not a limitation to engineer around.
- [ ] **Treat `410` as permanent** — never retry that URL. It must not be allowed to consume retries and reach the DLQ as though it were a transient failure.
- [ ] **Decide what "analysed" means without an engine.** Storing raw games is not analysis. Counting games, results, opponents and time controls is a real aggregate the dashboard can show — and it makes the phase demonstrable without Stockfish.
- [ ] **Confirm the 400KB item limit holds** for a month of games. A heavy month may not fit in one item, and finding that out after building is expensive.

## ETag caching — the cost story

**What it is for:** the skill calls this "the real cost story behind the retention loop". Chess.com refreshes data at most every 12–24h, so re-fetching an unchanged archive is pure waste.

- [ ] **Store the ETag** on the archive item when fetching.
- [ ] **Send `If-None-Match`** on re-fetch; a `304` means skip.
- [ ] **Prove the saving live** — a re-submit of an unchanged month should do no analysis work. Same standard as Phase 2's drills: watched, not asserted.
- [ ] Decide how a `304` interacts with the existing conditional-insert dedup. They solve overlapping problems at different layers, and the interaction needs to be deliberate rather than emergent.

## Presigned S3 upload — justify it or cut it

**What it is for:** the skill's Phase 3 lists it, and the "name the failure mode" rule outranks the list.

The honest position: **username ingestion needs no upload.** Archives are fetched server-side, so the presigned path only serves the *pasted or uploaded PGN* input from the skill's feature list. That input is real but it is not the main path, and no part of the app currently produces or consumes an uploaded file.

- [ ] **Decide whether this ships in Phase 3 at all.** It is the one item here with no failure mode in the current product. Options: build it for the upload feature, defer it until the upload feature is actually wanted, or cut it and record why.
- [ ] If built: presigned `PUT`, S3 event → SQS, and the same worker path. Do not add a second queue or a second worker.

## Idempotency — re-examined, not assumed

**What it is for:** SQS is at-least-once. Phase 1's argument was that duplicates are safe because analysis is deterministic and overwrites the same item — which was true of a hardcoded result.

- [ ] **Re-check the argument against real data.** A retry now costs an outbound API call, so "harmless" needs restating: is it still safe, and is it still cheap?
- [ ] Decide whether a partially-written archive can be distinguished from a complete one. A crash mid-write is the case that makes "overwrites the same item" less comforting than it sounds.

## Failure paths

Same standard as Phases 1 and 2: drills, watched live, not assertions.

- [ ] **Unknown username** → Chess.com returns `404`. Should not retry, should not reach the DLQ, and the item should end in a state a client can read.
- [ ] **`429` rate limit** → backs off and succeeds rather than burning retries.
- [ ] **`410` gone** → permanent, no retry, distinguishable from a transient failure.
- [ ] **Chess.com unreachable** → retries, then DLQ. The existing redrive already handles this; confirm it still does with a real HTTP client in the path.
- [ ] **Empty archive** (valid user, no games that month) → `COMPLETE` with zero games, not an error. A user with no games in March is not a failure.
- [ ] **Crash mid-fetch** → visibility timeout returns the message, and the retry does not double-count games.

## Cost controls

- [ ] Confirm ingestion stays inside the free tier. The outbound calls are free; the Fargate time is the cost, and it is per-second.
- [ ] **Know the per-archive cost** before the phase ends, and what drives it. The skill calls this the interview edge.
- [ ] Re-run `scripts/check-drift.sh` after each apply.
- [ ] Worker back to zero tasks after every drill. An idle task is ~$44/month and is the one cost mistake this design exists to avoid.

---

## Deviations from the roadmap

Phases 1 and 2 deviations are in their own files and still stand.

| Deviation | Skill says | We did | Why |
|---|---|---|---|
| _(next)_ | | | |

## Decision log

Phase 1 and 2 decisions are in [PHASE-1.md](PHASE-1.md) and [PHASE-2.md](PHASE-2.md) and remain binding.

| Decision | Chosen | Rejected | Why |
|---|---|---|---|
| _(next)_ | | | |

---

## Watch for

- **Ingestion is the phase; the engine is not.** If Stockfish appears here, the phase has failed its own brief. Phase 1's fake worker existed so that chess bugs and AWS bugs never arrive together — that argument still holds.
- **The API belongs to someone else.** Chess.com's constraints are not suggestions, and the cost of getting them wrong is an IP ban rather than a bill. Serialise, identify yourself, respect `410`.
- **Do not build the upload path out of obligation.** It is on the skill's list and has no failure mode in the current product. Deciding to cut it is a valid outcome and should be recorded as one.
- **"COMPLETE" now means something.** With a fake worker it meant the plumbing ran. It should now mean the data is actually there — and the difference needs to be visible in the item, not just implied.
- **Know the monthly cost and what drives it.** Phase 3 adds the first component whose cost scales with *use* rather than existing.
