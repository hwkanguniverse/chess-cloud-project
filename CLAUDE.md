# Phase 7 — Load, schedule and cost

**Goal:** know the numbers an interviewer asks for, measured rather than estimated — what the API does under load (p50, p99, where it breaks), and what the whole system costs per month and why. The skill's Phase 7 row is *"k6 load test with recorded p50/p99, DynamoDB Streams, EventBridge schedule, cost breakdown"*, and the skill's own pitch names the questions: *"what p99 was, what it cost"*.

**This phase maps to SAA and SOA.** It is also the last numbered phase, so it is where the project's story either closes with evidence or with estimates.

**The temptation here is to build the list.** Streams and a schedule are on the row, and both are easy to add. Neither has yet been tied to a failure mode *in this app* — and the rule that cut S3, verification, private subnets and a dashboard applies unchanged. The load test has its own trap: load-testing the wrong route. Anything that calls Chess.com can get the IP banned, which the skill calls *"the one risk money cannot undo"*.

Previous phases: [PHASE-1.md](PHASE-1.md), [PHASE-2.md](PHASE-2.md), [PHASE-3.md](PHASE-3.md), [PHASE-F.md](PHASE-F.md), [PHASE-E.md](PHASE-E.md), [PHASE-6.md](PHASE-6.md), [PHASE-4.md](PHASE-4.md), [PHASE-5.md](PHASE-5.md). Read them for decisions already made, and do not redo them.

**Owed from earlier phases:**
- ~~**Phase F's hosting is still blocked on choosing a domain.**~~ *Live at `https://chess.hoowenkang.com` since 6 Oct, from GitHub Pages: the account is unverified, so it cannot create CloudFront resources yet (Deviations below). CORS is live, allowing that origin only. **Still owed: the browser drills** (sign up, submit, watch history fill) on the real origin, and the AWS Support case on account verification.*
- ~~**Going public — the site *or* the repo — first needs Phase E's global daily ceiling.**~~ *Built and drilled 30 Sep (PR #9) — see the decision log.*

Account: `961868442307` · Region: `ap-southeast-1` · IAM user: `terraform-admin` (MFA enabled, break-glass since Phase 5)

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

*Access note: the skill is not readable from the CLI. It is exported as `aws-cert-plan.skill` (a zip containing `SKILL.md`) in `~/Downloads` and unpacked. **Updated 3 Sep 2026** to describe the project as of the end of Phase 6 — the stale "ECS + ALB + RDS, apply/screenshot/destroy" row is replaced by what was actually built, the private-subnet decision and its costing are recorded, and the apply/destroy discipline is narrowed to what bills hourly while idle. **Updated 30 Sep 2026** for the end of Phase 4: status (next is 5), the Phase 4 row, the architecture line (six Lambdas, two queues, two services, one GSI, one SNS topic), the `by-class` GSI in the data model, a "What Phase 4 settled" section, and a correction to Phase E's parallel-efficiency figure — part of its "batch tail" was duplicate evaluation. Previous version kept as `aws-cert-plan.skill.bak-20260930`. **Same day, the per-game cost was re-measured** from task lifetimes checked against the bill: ~$0.10 per 300-game player worst case, not $0.043 — see the skill's cost model. **Updated again 30 Sep 2026** for the end of Phase 5: status (next is 7), the Phase 5 row, the architecture line (CI through two OIDC roles), the Infra line, and a "What Phase 5 settled" section. Previous version kept as `aws-cert-plan.skill.bak-20260930-p5`. **Updated again the same day** for the CV push: account linking removed (Phase 2 row, the identity paragraph, the user-data model, five Lambdas), the global daily cap built, hosting's status (waiting on the domain registration, not the choice), and a note on the README. Previous version kept as `aws-cert-plan.skill.bak-20260930-cv`. **Updated 6 Oct 2026** for hosting: the status line (F live, repo public, 7 next), the Phase F row (Porkbun, the unverified account, GitHub Pages until CloudFront is allowed), and the domain and zone in the cost model. Previous version kept as `aws-cert-plan.skill.bak-20261006`.*

**Changes reach AWS through the pipeline** (Phase 5): anything under `terraform/`, `app/`, `tests/` or `scripts/` goes through a PR, whose plan is posted on it; merging applies, then smoke-tests and drift-checks. Docs commit straight to `main`. The laptop applies only as break-glass — then export `TF_VAR_image_tag` (see `terraform/worker`) and run `bash scripts/check-drift.sh` by hand.



---

## Where things stand

- **No load numbers exist.** The only latencies are Phase 4's X-Ray figures for single warm requests — `/player` 225 ms (big_tonka_t) and 499 ms (hikaru). Nothing says what happens at 10 concurrent users, or 100.
- **The API has one global limit: the stage throttle, 10 req/s with a burst of 20.** It is account-wide, not per user. A load test will measure it before it measures anything else, and it is also what a public launch would hit first.
- **The read routes are public and unauthenticated** (`/players`, `/player/…`, `/analysis/…`); they are the only routes safe to load. `submit` calls Chess.com, and `analyse` spends Fargate money — neither is load-testable.
- **Data goes stale unless someone re-submits.** Submit refreshes the live month; nothing happens on a clock. There is no schedule of any kind.
- **Nothing consumes table changes.** No Streams; the design derives everything on read (Phase E's rule: recompute, never accumulate).
- **Costs are measured per unit, not per month.** Evaluation ~$0.10 per 300-game player (re-measured against the bill, 30 Sep); ingestion ~$0.03 per first full history; CI ~9 Actions minutes per change; ECR ~$0.07/month. There is no whole-system monthly breakdown by service, and credits have hidden the real bill so far.
- ~~**The spending controls are per account only.**~~ *A global daily cap on games now bounds all accounts together (30 Sep).*

---

## To decide before building

Each has a real trade-off.

- [ ] **The load test: what question does it answer?** Candidates: *"what are p50/p99 for the read API at realistic load"*; *"where does it break, and how"* (the throttle's 429s, Lambda concurrency, DynamoDB); *"can it survive a launch-day spike"*. Also: which routes (read only — see above), which players (a small one and hikaru behave differently), from where (laptop or CI), and how hard — past the throttle is the only way to see it work.
- [ ] **DynamoDB Streams: name the failure mode, or cut it.** Candidates that exist in principle: pushing "analysis done" to a waiting page instead of polling; recomputing an aggregate when a game lands. The second contradicts derive-on-read. If nothing here is broken without it, cutting it is the answer the rule gives — and it is a stronger interview line than building it.
- [ ] **EventBridge schedule: for what?** Candidates: a daily refresh of each tracked player's live month, so profiles stay current without a re-submit (freshness; costs ingestion time and serialised Chess.com calls per player per day); a nightly drift/plan run (Phase 5 rejected it — revisit only with a new reason); nothing.
- [x] **The global daily ceiling: this phase, or not?** *Decided and built 30 Sep, ahead of the rest of this phase, as the precondition for hosting — see the decision log.* It is the missing control between this project and going public, and a cost control. **Options: build it here; leave it to Phase F's launch.**
- [ ] **The cost breakdown: what is the deliverable?** A per-service monthly table from Cost Explorer, before and after credits, with the drivers named — and where it lives (the skill's cost model, so the interview answer has one home).

## To build

*Written once the decisions above are made.*

## What must not change

Carried forward because the temptation to revisit them does not go away.

- [ ] **Ingestion stays pinned at `max_capacity = 1`.** Still the one risk money cannot undo — and the reason no load test may touch `submit`.
- [ ] **Scale-to-zero stays.** `MinCapacity == 0` per service, drift-checked. A load test is not a reason to keep anything warm.
- [ ] **No ALB, no NAT, no RDS.**
- [ ] **Both services stay in the purpose-built VPC**, with zero inbound rules. Drift-checked.
- [ ] **The Phase 4 alert path stays whole.** Drift-checked.
- [ ] **Changes go through the pipeline; no long-lived AWS keys in GitHub.** The CI trust is drift-checked.

## Failure paths to drill

*Written once the decisions above are made.* Same standard as every prior phase: watched live, not asserted.

## Cost controls

- [ ] **Price the load test before running it.** Lambda invocations and DynamoDB reads are cheap per request and not per test; know the figure for the request count planned.
- [ ] **Never load-test a route that spends money or calls Chess.com.**
- [ ] **Workers back to zero after every drill.**

---

## Deviations from the roadmap

Earlier phases' deviations are in their own files and still stand.

| Deviation | Skill says | We did | Why |
|---|---|---|---|
| Domain registered at Porkbun | Route 53 domain, registered manually | **`hoowenkang.com` at Porkbun** ($11/yr), delegated to a Route 53 hosted zone that Terraform manages (#14) | Route 53 refused the registration ("We can't finish registering your domain") and the support case went 4 days without a reply. The registrar is on no failure path here: ACM validation and every record need only the zone. Not Cloudflare, which requires its own nameservers. A later transfer in would cost about a year's renewal and may hit the same block |
| App served from GitHub Pages, not CloudFront | S3 + CloudFront + ACM | **GitHub Pages** via a `chess` CNAME, with GitHub's domain-verification TXT record in the zone (#16). The S3 bucket, OAC and certificate from #15 remain; `cloudfront_enabled = false` gates the distribution | CloudFront refused the distribution: *"Your account must be verified before you can add new CloudFront resources"*, the same account-level block as the domain. That failure left the pipeline red before the smoke test and drift check on every merge. Pages unblocked both and needs no stored credential. Costs: deep links return HTTP 404 (served by `404.html`, but the page works), and the site is outside AWS. Revert once the account is verified |
| Account linking removed | *"Identity is two problems, not one"* — per-platform linking, Lichess OAuth PKCE verified, Chess.com unverified; built in Phase 2 | **Removed on 30 Sep:** `link.py`, its Lambda, role, log group and four routes; `lichess` dropped from the read routes' platform check | Linking existed to prove ownership, and Phase E cut verification because analysis is public — so ownership proves nothing the data does not give. The web app never called any link route, the table held **zero** link items, and the Lambda last ran on 19 Aug. It was also the only unauthenticated callback route and the only code calling lichess.org. Named-failure rule: nothing breaks without it. The Phase 2 reasoning stands as a record of what was built and why |

## Decision log

Earlier decisions are in [PHASE-1.md](PHASE-1.md), [PHASE-2.md](PHASE-2.md), [PHASE-3.md](PHASE-3.md), [PHASE-F.md](PHASE-F.md), [PHASE-E.md](PHASE-E.md), [PHASE-6.md](PHASE-6.md), [PHASE-4.md](PHASE-4.md) and [PHASE-5.md](PHASE-5.md), and remain binding.

| Decision | Chosen | Rejected | Why |
|---|---|---|---|
| Global daily cap | **3,000 games queued per UTC day across all accounts** (~$1/day worst case, ~$30/month if hit daily). `analyse` reserves `len(todo)` games on `GLOBAL#analyse / DAY#<date>` in one conditional `UpdateItem` — *before* the caller's token, so a full day charges nobody — and returns **503** with `retryAfter` to 00:00 UTC; released if the token then refuses | 1,500 or 6,000 games/day; leave it to the launch; cap requests rather than games | The per-account bucket cannot bound total spend while accounts are free — the hole Phase E named and Phase F's earlier spending-stop cut predated. Games, not requests, because games are the cost, so the cap is a cap in dollars. A counter does not break derive-on-read: that rule is about stored *results*; this is admission control, like the bucket. No new IAM, so it could not repeat Phase 4's grant-and-code outage. **Drilled 30 Sep:** counter set to 2,999 → theohwk's 14 games refused with 503, counter unchanged, token bucket untouched, claim released, queue empty; counter deleted → 202, 14 queued, counter 14, bucket 5 → 4 |
| Players directory | **A sparse `directory` GSI keyed on `archive`** (the month string every month item already carries, and nothing else does), sort key `PK`; `/players` Scans the index, and its role may Scan *only* the index | Keep Scanning the table; a "load more" cursor over the table Scan | Built 30 Sep, the listing GSI PHASE-3 planned and deferred until the Scan could be watched failing. It had: 203 month items among 83,427, so the 20-page limit stopped after 2 of 3 players and missed hikaru (70,840 games). Now 1 page, 9 read units, 0.26 s, complete. No backfill — the key attribute already existed, so DynamoDB filled the index itself. **Three PRs, in the safe order:** index + grant (#11), code (#12), remove the table grant (#13). **Found on the way:** the plan showed `by-class` removed and re-added — rehearsed on a throwaway table, it stayed `ACTIVE` and CloudTrail recorded only `create: directory`; the provider displays any index-set change that way. A GSI takes ~8.5 min to create even on an empty table |

---

## Watch for

- **A load test measures the first limit it hits, not the system.** At 10 req/s that is the stage throttle; a p99 read past it is a p99 of 429s.
- **Cold starts dominate a short test.** Six Lambdas at zero warm instances; the first seconds of any run are a different distribution from the rest.
- **Credits hide the bill.** Cost Explorer shows usage and credits as separate record types — read both, or the breakdown says $0.
- **The most dangerous failures look like success.** Every phase so far found one; this one will too.
- **Deploying is a distinct test from running.**
- **`aws logs` needs `MSYS_NO_PATHCONV=1` in Git Bash on Windows.**
