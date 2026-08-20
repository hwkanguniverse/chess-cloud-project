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
- **Before starting the next phase, re-read the skill and update it to match what this project actually is.** Not a changelog and not a record of what changed during the phase — the skill should simply describe the project accurately as it now stands. Anything it says that is no longer true gets corrected; anything the project now does that it does not describe gets added. Phase 3 alone has cut the S3 upload path, moved submit from player-month to whole-player fan-out, and added a player-level read — a skill still describing the old shape would mislead the phase that reads it next.

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

**Submit now takes a username alone and fans out.** The user-month is still the unit of work; it is no longer the unit of request. Submit resolves `GET /pub/player/{username}/games/archives` — a list of every monthly archive URL the player has — and enqueues one message per month. The worker is unchanged in shape: one message, one request, one item.

- [x] **Resolve the archive list at submit** — `GET /pub/player/{username}/games/archives`, then one message per month returned. Verified: `hikaru` → 152 archives, 152 claimed, 152 messages (batched 10 at a time); re-submit → 0 queued, 152 skipped.
- [x] **Lichess rejected at submit.** It has no archive-list endpoint — it is in this app for account linking (Phase 2), not ingestion. Accepting it would produce a confusing upstream 404 instead of an answer.
- [x] **Player read route** — aggregate on read. One Query on `PLAYER#<platform>#<username>` returns every month with its own status and counts, plus cumulative totals over the COMPLETE ones. No player-level progress item to keep in sync; correct for partial progress by construction. Verified: 3 of 152 months done → `pending: 149`, totals over exactly those 3.
- [x] **Games are not in the player response.** Per-month summaries only — 7.8KB for 152 months. Including the games would be tens of megabytes. The games live on the existing per-month route: the player page lists months, drilling into one shows its games.
- [x] **Fan-out is uncapped** — every archive the player has. Measured: `hikaru` is 152 months. The first pass is slow by design; the user waits and watches months fill in. This is affordable because the cost is a one-off: a re-submit returns `304` for every unchanged month at 0.15s each, so the expensive pass happens once per archive, ever.
- [x] **Cumulative summary on the player route** — totals across completed months (games, W/D/L, rating range, time-control split), computed from the same Query that returns the month list. Correct for partial progress by construction: 40 of 152 months done means totals over those 40. No stored running total — a counter updated by 152 workers is write contention solving a problem that arithmetic already solves.
- [x] **Fetch a monthly archive** — `GET /pub/player/{username}/games/{yyyy}/{mm}`. One request per queue message, which is what "one message per user-month" already set up.
- [x] **Send a User-Agent with contact details.** Sent by both the worker and submit, carrying the project name and a contact address. Overridable by env var so it never has to be edited in code.
- [x] **Serialise per user.** Unchanged and now load-bearing: the worker takes one message at a time (`MaxNumberOfMessages=1`) and a single task processes them in sequence. Nothing was added for this — it is a property of the existing loop, which is why "scaling out the worker" is the change that would silently break it.
- [x] **Treat `410` as permanent** — raised as `PermanentFailure`, written as `FAILED` with the upstream reason, message deleted. Never consumes a retry, never reaches the DLQ.
- [x] **Decided what "analysed" means without an engine** — counted, not evaluated: games, W/D/L, colours split, time-control split, rating min/max/last per month, and cumulative totals across months. Real numbers a dashboard can show, demonstrable without Stockfish.
- [x] **Store a summary row per game**, not the PGN: date, opponent, both ratings, colour, result, time control, game URL. 179 bytes each. Full move data is Phase 4's problem, under Phase 4's storage decision.
- [x] **Confirmed the 400KB item limit holds** — measured against the live API, not estimated. Heaviest month sampled from `hikaru` (18 months, 2025-03 → 2026-08) was 828 games. Summary rows: **179 bytes/game, 145KB, 36% of the item limit**, ceiling ~2,288 games per month. Re-measure before adding any field to the row — the first cut of the row was 243 B/game and 49% of the limit.
- [ ] **Opening name deferred, not rejected.** Chess.com's `eco` field is a URL ending in the opening *name*, not the ECO code — up to 66 characters, which alone was a third of the item budget. Cut because nothing reads it yet. Opening statistics are a real thing to show a player; if they come back, they need their own storage decision rather than a field on every row.
- [x] **Full PGNs are impossible in one item, confirmed** — that same archive is **3.4MB raw**, over 8x the limit. The summary-row decision is now measured rather than assumed.

## ETag caching — the cost story

**What it is for:** the skill calls this "the real cost story behind the retention loop". Chess.com refreshes data at most every 12–24h, so re-fetching an unchanged archive is pure waste.

**Verified live before building.** The archive endpoint returns a weak ETag (`W/"d44f69…"`), and `If-None-Match` on an unchanged month returns **304, 0 bytes, 0.15s** versus **200, 3.4MB, 0.81s** for the full fetch. The saving is real and measured.

**`Last-Modified` is not a fallback.** The header is present, but `If-Modified-Since` returned a full `200` with the whole body. Only the ETag path short-circuits — do not treat the two validators as interchangeable.

- [x] **Store the ETag** on the archive item when fetching.
- [x] **Send `If-None-Match`** on re-fetch; a `304` skips the parse, the aggregate and the games write entirely — only a `checkedAt` / `lastCheckHit` note is written, so the saving is visible in the item rather than merely claimed.
- [x] **Saving proven live, 20 Aug 2026.** Forced one month of `chesscom/erik` to `FAILED`, re-submitted, and watched the worker log `unchanged, skipping chesscom/erik/2026-01`. The item afterwards: `lastCheckHit: true`, `checkedAt` bumped, **`analysedAt` unchanged 23 minutes earlier**, `summary.games` still 81. The month returned to `COMPLETE` without re-downloading 3.4MB.
- [x] **And proven on the normal path** once the live-month refresh existed. Re-submitting `erik` → `queued: 1, skipped: 229, refreshed: true`; the worker logged `fetching chesscom/erik/2026-08 (conditional)` then `unchanged, skipping`. This is the ETag doing its actual job rather than a forced `FAILED` re-claim — **the caching only became load-bearing once something routinely re-queued a month.** Built early, dormant until the refresh gave it a reason to run.
- [x] **`304` and dedup are at different layers, deliberately.** Dedup runs at *submit* and asks "is this month already claimed?" — a `COMPLETE` month is never re-queued, so the worker never sees it and the ETag never comes into play. The ETag runs at the *worker* and asks "has this month changed since we fetched it?" The two only meet on a `FAILED` month, which submit re-queues and the worker then re-fetches conditionally. Net: dedup makes re-submits free at the front door, and the ETag makes them cheap when a month legitimately does get re-queued.
- [x] **Re-claiming a month must not erase its ETag.** Submit uses `UpdateItem`, not `PutItem`. This was found the hard way: the first drill of the above re-fetched the month *in full* despite a correct stored ETag, because `PutItem` replaces an item wholesale and wiped it. The two layers meet on exactly one attribute, and the write that re-claims a month is the one that can destroy it.

## Presigned S3 upload — cut

**Settled.** Users will not upload their own PGN, so there is no file input in the product and nothing for a presigned `PUT` to serve. No S3 bucket, no S3 events, no second queue. Recorded in the deviations table and the decision log.

This is a product decision rather than a sequencing one: it does not return in Phase 4 unless the product itself changes.

## Idempotency — re-examined, not assumed

**What it is for:** SQS is at-least-once. Phase 1's argument was that duplicates are safe because analysis is deterministic and overwrites the same item — which was true of a hardcoded result.

- [x] **Re-checked against real data. Still safe, and cheaper than before.**
  - *Safe*: the aggregate is computed from the archive Chess.com serves, not accumulated onto what is stored. `aggregate()` builds its totals from scratch each time, so a duplicate delivery recomputes the same numbers and overwrites the item with them. Counts cannot drift upward on a retry, which was the failure worth worrying about.
  - *Cheap*: a duplicate now costs a GetItem and a conditional HTTP request. Because the first delivery stored an ETag, the retry sends `If-None-Match` and gets a `304` — **$0.0000012, no parse, no games write**. The retry path is the cached path, so at-least-once delivery is 155x cheaper on the second delivery than the first.
- [x] **A partial write cannot happen — there is nothing to interleave.** Games, aggregate, ETag and `status` are set in a *single* `update_item`. DynamoDB applies one item write atomically, so the item either still holds the previous state or holds the complete new one; there is no window where `COMPLETE` is visible without the data behind it. This is why the write is one call rather than a status update followed by a data update — the two-call version is what would have made "overwrites the same item" unconvincing.
  - The remaining crash windows are both benign: crash *before* the write leaves the item as it was and the message reappears; crash *after* the write but before the delete replays a message whose work is already done, which is the `304` path above.

## Failure paths

Same standard as Phases 1 and 2: drills, watched live, not assertions. Drilled against the deployed stack 20 Aug 2026 using `chesscom/erik` (230 archives).

| Path | Behaviour built | Drilled live |
|---|---|---|
| **Unauthenticated submit** | `401` at the gateway, before any Lambda runs. | ✓ `401` |
| **Unknown username** | Caught at *submit* on the archive-list call → `404`, no item, no message. Never reaches the worker. | ✓ `404` in 1.4s |
| **Lichess submit** | Rejected at submit — no archive-list endpoint exists, so accepting it would produce a confusing upstream 404. | ✓ `400` |
| **Real ingestion** | 230 archives → 230 messages → 230 fetched, **zero failures, zero 429s**. Queue drained 230 → 0 in ~3 min on one task. | ✓ |
| **Empty archive** | `200` with zero games, *not* a `404`. `aggregate([])` gives zeroes and the month is `COMPLETE`. | ✓ live API |
| **Re-submit (dedup)** | 230 archives → **0 queued, 230 skipped**. The worker never wakes. | ✓ |
| **`304` unchanged** | Re-queued month → `unchanged, skipping`, `analysedAt` untouched. | ✓ |
| **`FAILED` re-submittable** | Forced `FAILED` → **1 queued, 229 skipped**, stale `error` cleared, ETag preserved. | ✓ |
| **`404` at the worker** | `PermanentFailure` → `FAILED` with Chess.com's message, message deleted, DLQ untouched. | ✓ **occurred naturally** |
| **Crash mid-fetch** | Task killed mid-drain with 109 messages queued and 1 in flight. Recovered on restart: 149/149 months processed, no double-counting, DLQ empty. | ✓ |
| **`429` / `410` / `5xx`** | `429` backs off 2s → 4s then gives up to the queue; `410` permanent; `5xx` retries → DLQ. | ☐ simulated only |

**The worker-side `404` drilled itself, 20 Aug 2026.** Ingesting `danielnaroditsky` (149 archives), **8 months came back `404` from the archive endpoint despite being listed by the archive list** — Chess.com's own text is "An internal error has occurred". Re-checked by hand afterwards: still `404`, so genuinely permanent rather than a blip. This is the exact case the permanent/transient split exists for, and the payoff is measurable: had those 8 taken the generic retry path they would have burned 3 receives each and put **24 messages in the DLQ**, drowning the one signal that means something is broken. Instead the DLQ stayed empty and each failure is readable on its item. The upstream is less consistent than the plan assumed — a real finding, not a hypothetical.

**Still simulated:** `410`, `429` and `5xx`. Chess.com will not produce those to order, and drilling them for real would mean making `API_ROOT` an env var so the worker could be pointed at a fake host — a production change whose only purpose is testing. Not done; flagged as a deliberate gap rather than an oversight.

## Deploy — live as of 20 Aug 2026

- [x] **Terraform: player route** — `GET /player/{platform}/{username}` → new `player` Lambda, unauthenticated like the per-month status route.
- [x] **Terraform: submit** — new code, timeout 10s → **20s** (a real 230-month submit takes 9.4s, so 10s was a coin flip), UA env var, IAM corrected.
- [x] **Rebuild and push the worker image.** Verified before pushing that the image contained the real worker — no `time.sleep(10)`, no `fake`.
- [x] **`check-drift.sh` clean** after both applies.
- [x] **`status.py` docstring corrected** — it now describes itself as the drill-down from the player route rather than the thing a client polls after submit.
- [x] **Skill updated** — `aws-cert-plan-phase3.skill` in Downloads, rewritten to describe the project as it now stands (not a changelog). Needs uploading to the Claude account to replace the current version.

**Three bugs found by deploying, none of which the local tests could have caught:**

| Bug | Symptom it would have caused |
|---|---|
| Submit lacked `sqs:SendMessageBatch` | Every fan-out fails with AccessDenied. It is a *distinct* IAM action from `SendMessage`, not a variant. |
| Worker lacked `dynamodb:GetItem` | Every message fails *generically* — so all 230 retry five times into the DLQ looking exactly like a Chess.com outage. |
| Player route ignored pagination | **Silent truncation.** DynamoDB caps a Query at 1MB, so it returned 87 of erik's 230 months with no error and plausible-looking totals — 7,475 games instead of 16,321. Fixed with pagination plus a `ProjectionExpression` that drops the games arrays, which also made the route 4x faster (8.0s → 1.8s). |

## Cost controls

- [x] **Per-archive cost, measured** (ap-southeast-1, 0.25 vCPU / 0.5 GB):

  | | Cost |
  |---|---|
  | One month, full fetch + write | $0.000186 |
  | One month, `304` unchanged | $0.0000012 — **155x cheaper** |
  | Hikaru's full 152-month history, first pass | **$0.028** |
  | Same history re-submitted, all cached | **$0.0002** |

  **The 155x gap is the phase's cost story in one number.** Ingestion itself is free in practice; the work is too cheap to be worth optimising further.
- [ ] Confirm ingestion stays inside the free tier. The outbound calls are free; the Fargate time is the cost, and it is per-second.
- [ ] Re-run `scripts/check-drift.sh` after each apply.
- [ ] Worker back to zero tasks after every drill. **An idle task at this size is ~$12/month** — against $0.028 for a player's entire history, which is the whole point: idle time is the only cost that can hurt. (The ~$44 figure carried from earlier phases was for a larger task size; corrected here.)

---

## Deviations from the roadmap

Phases 1 and 2 deviations are in their own files and still stand.

| Deviation | Skill says | We did | Why |
|---|---|---|---|
| Presigned S3 upload | Phase 3 ships presigned `PUT` → S3 event → SQS | Cut. No bucket, no upload path, no S3 in the project | The product has no file input. Ingestion is username-only and fetched server-side, so nothing produces a file to upload. The skill's own "name the failure mode" rule outranks its feature list, and there is no failure mode here. Not deferred pending a decision — the owner has ruled out user-supplied PGN entirely, so this does not return unless the product changes. |
| Submit granularity | One queue message per user-month, submitted as one | Submit takes a username only and fans out to one message per month | The user-month remains the unit of *work*; it is no longer the unit of *request*. See the decision log below — the fan-out preserves every constraint the skill placed on the worker. |

## Decision log

Phase 1 and 2 decisions are in [PHASE-1.md](PHASE-1.md) and [PHASE-2.md](PHASE-2.md) and remain binding.

| Decision | Chosen | Rejected | Why |
|---|---|---|---|
| Presigned S3 upload | Cut from the project | Build it now; defer it until an upload feature is wanted | Users will not upload their own PGN. Confirmed by the owner as a product decision, not a sequencing one — so "defer" was the wrong shape for the answer. Building it would have meant infrastructure whose first exercise was a synthetic test invented to justify it. |
| Submit input | `username` only; the system pulls every archive the player has | `username + archive` (one month per request) | Asking a user which month to analyse pushes a detail of Chess.com's API into the product. The interesting question is a player's history, not one month of it. |
| Whole-player shape | Fan out: submit resolves the archive list and enqueues one message per month | One message per username, worker loops all months internally | The looping worker puts ~96 HTTP requests inside one visibility timeout, and a crash at month 80 restarts at month 1. Fan-out keeps the worker exactly as the skill constrained it — one message, one request, one item — and keeps per-month progress durable. It is also what makes the ETag story real: 95 unchanged months return `304` and only the current month does work. |
| Archive-list fetch location | Submit handler resolves `/games/archives` before enqueueing | Worker resolves it and self-enqueues | The list is one fast request and the client benefits from knowing the job size at submit time. A self-enqueueing worker also blurs the one-message-one-request rule the skill sets. Cost: submit is no longer purely local — see the open risk in the ingestion section. |
| Fan-out cap | None — every archive the player has, however many | Cap to the last N months | The cost is one-off, not recurring: ETag re-validation makes every subsequent pass ~0.15s per unchanged month. A cap would trade completeness for a saving that only ever applies to the first submit. The user waits; the page fills in as months land. |
| Cumulative totals | Computed on read from the per-month items | Stored running total on a player item, updated per worker | Arithmetic over a Query the route already performs. A stored counter written by up to 152 concurrent workers is contention and drift for no gain, and would need care to stay correct while months are still arriving. |
| Refreshing a player | Re-queue the **live month only**; past months skipped forever | Re-queue nothing (the original); re-queue everything; check ETags at submit | A past month is immutable — 2019 will never gain a game. The current month is still being played, and it was the *one* month dedup was skipping, so re-submitting a player picked up no new games at all. Checking ETags at submit was the tempting fix and does not work: 230 conditional requests inside a request capped at 29s. The check belongs on the worker, where nothing is waiting. Computed in UTC, because that is how Chess.com keys archives. |
| Re-claiming a month | `UpdateItem` on named attributes | `PutItem` replacing the item | `PutItem` replaces an item wholesale, erasing the stored ETag and forcing a full re-download of an unchanged archive. Found by drilling, not by reading: the first `304` drill re-fetched 3.4MB despite a correct ETag. Cost: `archive`, `status` and `username` are DynamoDB reserved words and must be aliased in an `UpdateExpression` — a constraint `PutItem` does not have. |
| Player route reads | Paginated Query + `ProjectionExpression` | Single Query, filter fields in Python | A Query caps at 1MB, which for a long-lived player is a fraction of their history — and it truncates *silently*, returning plausible totals. Projecting the games away server-side also stops DynamoDB reading 145KB-per-month arrays that the route discards, which is where the 4x speed-up came from. |

---

## Watch for

- **Ingestion is the phase; the engine is not.** If Stockfish appears here, the phase has failed its own brief. Phase 1's fake worker existed so that chess bugs and AWS bugs never arrive together — that argument still holds.
- **The API belongs to someone else.** Chess.com's constraints are not suggestions, and the cost of getting them wrong is an IP ban rather than a bill. Serialise, identify yourself, respect `410`.
- **Do not build the upload path out of obligation.** It is on the skill's list and has no failure mode in the current product. Deciding to cut it is a valid outcome and should be recorded as one.
- **"COMPLETE" now means something.** With a fake worker it meant the plumbing ran. It should now mean the data is actually there — and the difference needs to be visible in the item, not just implied.
- **Know the monthly cost and what drives it.** Phase 3 adds the first component whose cost scales with *use* rather than existing.
