# Phase F — Frontend & Going Public

**Goal:** put a face on the system and open it to real users. Three phases in, the only way to see anything this project does is `curl` and CloudWatch logs. By the end of this phase a stranger can visit a domain, sign up, submit a chess username, and watch their history fill in.

**This is the phase where assumptions stop holding.** Every safety property so far has rested on there being exactly one user who knows how the system works and does not try to break it. Real users replace that assumption with actual limits — which is what the security work below is, and why it belongs *in* this phase rather than after it.

**Out of order, deliberately.** The skill's build order was `1 → 2 → 3 → 6 → 4 → 5 → 7`, so Phase 6 (VPC) was next. Two unnumbered phases are inserted after 3 instead — **F (this one), then E (Stockfish)** — because the product has real aggregate data now and no way to look at it, and because an engine that produces eval graphs is worth less than the page that would display them. Recorded as a deviation below.

**Stockfish is not in this phase.** It is Phase E, immediately after. Worth stating because the roadmap never scheduled the engine at all — the numbered phases map to certifications and none of them is "add the engine", so it had no home until now. Earlier notes in this repo said "Phase 4", which was wrong twice over: wrong in the order, and Phase 4 is observability.

Account: `961868442307` · Region: `ap-southeast-1` · IAM user: `terraform-admin` (MFA enabled)

---

## How we work on this

Unchanged from Phases 1–3, and still the point. **Claude writes the code. I make the decisions, after I understand them.**

- **Explain first, then write.** What problem it solves in *this* app, what breaks without it, what it costs. Then I decide.
- **Ask, don't assume.** Any choice with a real trade-off is mine.
- **Name the failure mode** a service exists to handle here. "Real systems use it" gets it cut — that rule cut S3 in Phase 3 and it still applies.
- **Tick items off in this file as they are completed.**
- **Record decisions in the log below** — choice, alternative, reason.
- **Say when I am wrong, and why.**

Run `bash scripts/check-drift.sh` after every apply.

---

## Where things stand

Phase 3 left the backend genuinely ready for this, and the frontend now exists. What is missing is everything that would let anyone *else* reach it.

| | Status |
|---|---|
| Ingestion, ETag caching, failure handling | Done and drilled |
| Player and month read routes | Live, unauthenticated, public by design |
| Cognito pool, JWT authorizer, SRP login | Live since Phase 2 |
| Frontend | **Built** — submit, player dashboard, games list, directory, login. Runs on localhost only |
| **CORS** | **Absent entirely.** No browser on another origin can call the API |
| **Hosting** | Nothing. No domain, no certificate, no bucket, no distribution |
| **Per-user rate limits** | None. The 10 req/s throttle is shared across all callers |
| **Spending stop** | None. The $5 budget is a *forecast alert* — it emails, it does not stop |

---

## The frontend

**What it is for:** the aggregate dashboard is the product, per the skill. The data exists — 149 months and 129,391 games for one player already in the table — and nothing can display it.

**Built, and running locally only.** Three routes in [App.tsx](web/src/App.tsx) over a token-based component set. Nothing below is reachable by anyone else until Hosting and CORS exist — that is the whole of what stands between this and a usable site.

- [x] **Submit page** — one input (Chess.com username), posts to `/games`, shows what came back, then navigates to the player page after 1.2s so the counts are readable rather than flashing past. Username is validated client-side against a copy of `USERNAME_RE` from `submit.py` — a convenience to avoid an obvious round trip, not a control.
- [x] **Player dashboard** — polls `/player/{platform}/{username}`, renders cumulative totals and a progress bar that fills as workers finish.
- [x] **The games list is flat, not per-month.** Months are the *fetch* unit, never a presentation unit: `loadMore()` walks completed archives newest-first purely as a pagination source and concatenates them into one reverse-chronological list. Each batch is sorted before appending, so the list stays ordered without ever re-sorting thousands of rendered rows.
- [x] **Login** — Amplify `<Authenticator>` on the one screen behind the JWT authorizer. Reads stay public; only submit needs a token.
- [x] **Partial data is the normal state, and the page is built for it.** Totals are over COMPLETE months only, so they climb as months land; the progress bar appears only while `pending > 0`; a failed poll renders "retrying" beside stale data rather than replacing the page with an error.
- [x] **Player directory** (`/players`) — not in the original plan. The player page needs you to already know a username; this hands out the list, and makes the "analysis is public shared data" decision visible rather than merely stated.
- [x] **Games list stays on the player page, with no URL of its own.** Built as a separate `/games` route, then reverted: measuring what the URL would link *to* showed there was nothing worth linking. A page loads in a fraction of a second, so there is no long-lived scroll position to share, and the accumulating "load more" state cannot be honestly encoded in a URL anyway — a page number drifts as months complete, and an archive would put months back in front of the user. One page, one URL.
- [x] **Totals are withheld until every month is in.** Mid-ingest they are not a partial view of the answer but a different, smaller one that looks identical: totals cover COMPLETE months only, so a win rate over 3 of 230 months is a number someone will read and believe. Gated on `pending`, which counts PENDING only — gating on "not COMPLETE" would mean the player with 8 permanently-404 archives never sees totals at all.

**Two corrections to what this section used to say.** Both were plans the build deliberately departed from, left here uncorrected until now:

- It specified a **month drill-down at `/analysis/{platform}/{username}/{yyyy-mm}`**. That was the storage shape leaking into the product — the same mistake the Phase 3 log already rejected when submit moved from player-month to username-only. The backend splits by month because the player route projects the games arrays away (145KB per month); the *user* has no month-shaped question. Built as pagination instead.
- It specified the **Cognito Hosted UI with authorization-code + PKCE**. Built with Amplify's `<Authenticator>` over SRP instead: the pool allows only `ALLOW_USER_SRP_AUTH` and `ALLOW_REFRESH_TOKEN_AUTH`, the password never reaches Cognito, and sign-up, confirmation and password reset come from one element. Consequence to keep in view: **there is no hosted callback URL in this design**, so the `localhost:3000` callback parked in Phase 2 is not what unblocks login in production — the app client's allowed origins are.

## Hosting

**What it is for:** static files need somewhere to live, and the login flow needs HTTPS on a real domain — S3 website endpoints are HTTP-only, so they cannot serve a Cognito callback.

- [ ] **Route 53 domain** — registered manually (~$12–15/yr depending on TLD). Hosted zone ~$0.50/month.
- [ ] **ACM certificate** — free, but **must be issued in `us-east-1`** regardless of where everything else lives. CloudFront only reads certificates from there. This is the single most common way this setup fails.
- [ ] **S3 bucket, private** — no public access, no website hosting. CloudFront reads it through Origin Access Control.
- [ ] **CloudFront distribution** — HTTPS, custom domain, SPA fallback so client-side routes do not 404 on refresh.
- [ ] **Deploy step** — `npm run build` then sync to S3, plus a CloudFront invalidation. 1,000 invalidation paths/month are free; more are billable, so invalidate `/*` sparingly.

## Security — in this phase, not after it

**What it is for:** each item below is a thing that is currently safe *only because there is one user*.

- [ ] **CORS on the API.** Nothing works in a browser without it. Allow the real origin explicitly — not `*` — since the authenticated routes carry a bearer token.
- [ ] **Decide what happens to the unused Hosted UI.** `terraform/auth` still provisions the whole authorization-code setup — a Cognito domain, `allowed_oauth_flows = ["code"]`, and callback URLs parked at `localhost:3000` — but the app signs in with Amplify SRP and never visits it. It is live, publicly reachable, and can create real accounts in the pool by a path the app does not control. Either delete it or state why it stays; leaving a second front door open by accident is the kind of thing this section exists to catch.
- [ ] **Per-user rate limiting.** The stage throttle (10 req/s) is shared, so one person's polling loop degrades the site for everyone. Bound a single caller, not just the total.
- [ ] **Worker concurrency pinned at 1.** *Chosen guard for the upstream.* Serialised ingestion is currently a property of the autoscaling max rather than an enforced invariant — make it explicit, because "scale the worker out" is the optimisation that would silently break the constraint Chess.com actually cares about. See the scaling note below for what to do when one worker is no longer enough.
- [ ] **A real spending stop.** Decide what happens when the budget is exceeded rather than forecast-exceeded. The current alert emails and nothing else.
- [ ] **Cognito signup is open** — confirmed decision. Consider email verification and whether an unverified account may submit.
- [ ] **Review what a token can do.** Submit is the only authenticated route and it costs money per call. Reads are public and always were.

## Scaling the worker — staying at one, and why the obvious paths are unproven

**Decision: one worker. Not as a stepping stone to a known upgrade — as the only configuration known to comply.**

Chess.com's rule is *"serial access is unlimited; parallel requests may return `429`"*. Read it carefully: it is phrased per **caller**, not per player. Nothing in it says two concurrent requests are acceptable provided they are for different usernames. Two workers on `hikaru` and `erik` are still two of our requests overlapping in time, which is what the rule appears to prohibit.

That matters because it kills the intuitive scaling story. "Multiple workers, one player each" sounds safe and may not be; "multiple workers on the same player, different months" is the same question wearing a different hat. Under the strict reading, **no horizontal scaling is safe** — and the strict reading is the one to build against, because the failure mode is an IP ban. Every other risk in this project is capped by money. This one is not: it breaks the product for every user and cannot be bought back.

**An earlier draft of this file asserted the invariant was "never two concurrent requests for the same username" and named SQS FIFO as the upgrade path. That was under-evidenced** — it assumed a per-player limit the API's own wording does not state. Corrected here rather than left to mislead.

**The prerequisite to scaling is finding out the real limit, not choosing a mechanism.**

- **Ask.** The contact address is already in the User-Agent, which is exactly what it is for, and Chess.com's developer community is the right channel. "I run a serialised ingester; what concurrency is acceptable?" An answer in writing beats any amount of inference.
- **Measuring is weak evidence.** No `429` at concurrency 2 for five minutes does not prove it is safe sustained, and a false negative here costs the product.

**If** the limit turns out to be per-player, the mechanisms below enforce that — listed as tools for a constraint not yet confirmed, not as a plan:

| Option | How it would enforce per-player serialisation | Cost |
|---|---|---|
| SQS FIFO + `MessageGroupId` = username | At most one in-flight message per group, so one player's months serialise while different players proceed. | A different queue: new queue, new redrive, re-point submit and worker. |
| DynamoDB lock per username | Conditional write claims the player before fetching, released after. | Distributed locking, with lease expiry and crash-holding-the-lock to answer. |

**There is no throughput problem today.** One worker drained 230 months in ~3 minutes and 149 in about the same. The trigger to revisit is *drain time becoming visible to users* — and even then, the first action is asking Chess.com, not raising `max_capacity`.

## Known limitation, accepted knowingly

**One user can still queue ~200 months in a single submit.** Worker concurrency protects *Chess.com* — upstream never sees parallel calls, which is the ban risk and the one that cannot be fixed with money. It does not protect *other users*: ten people submitting long-lived players is ~2,000 messages through one serialised worker at ~0.8s each, roughly 27 minutes of drain, and everyone waits.

Not a safety problem — nothing breaks, nothing is banned, the bill stays trivial. A fairness and latency problem, and only at concurrency this project has never had. Shipping without a per-submit cap is deliberate: it is reversible, the fix (fetch recent months first, older on demand) is also better UX, and real traffic would say whether it is worth building. **Revisit if queue drain time becomes visible to users.**

## Cost

- [ ] Confirm the total stays where it should: **under ~$2/month** — CloudFront + S3 pennies, hosted zone ~$0.50, ingestion effectively free ($0.028 per player's entire history).
- [ ] **Deliberately not buying:** WAF (~$5–8/month, more than the entire current spend). Revisit if abuse actually appears.
- [ ] Domain registration is the real recurring cost, and it is annual not monthly.
- [ ] Worker back to zero tasks after every drill. Remains the one cost mistake that matters. ~$12/month is the *on-demand* price of an idle task; the worker runs on FARGATE_SPOT, so the real figure is roughly 70% less — still the largest avoidable line item in a ~$2/month budget.

## Failure paths to drill

Same standard as every prior phase: watched live, not asserted.

- [ ] **Signup → login → submit** end to end from the browser, as a new user.
- [ ] **CORS preflight** — confirm the browser's `OPTIONS` is answered, not just the `GET`.
- [ ] **Expired token** mid-session → the page recovers rather than silently failing.
- [ ] **Submitting a bad username** → the `404` surfaces as a message, not a broken page.
- [x] **Watching a fan-out live** — ✓ 26 Aug 2026, unplanned. `theohwk` sat at 22 PENDING months and 0 games, which looked like a stuck ingest and was not: the `queue_has_work` alarm is `period = 60`, `evaluation_periods = 1`, and SQS publishes queue depth on a lag of its own, so scale-out trails a submit by a minute or two. Autoscaling set desired count to 1 at 13:17:10 and all 22 months drained to COMPLETE — **1,502 games** — within a few minutes. The directory row showing 0% was an accurate picture of a real intermediate state, which is what that UI is for. Also the first live exercise of the withheld-totals state above.
- [ ] **Direct navigation to a deep link** (`/player/chesscom/erik`) → CloudFront serves the app, not a 404. This is the deepest link the app has, by decision rather than by omission — see the games-list item above.

---

## Deviations from the roadmap

| Deviation | Skill says | We did | Why |
|---|---|---|---|
| Phase order | `1 → 2 → 3 → 6 → 4 → 5 → 7` | Frontend inserted before 6 | Three phases of infrastructure with no way to see any of it. The aggregate dashboard is what the skill itself calls "the actual product", and the data for it already exists. |
| Frontend scope | "Not building: a real frontend beyond a page that posts and polls" | React with a build step | Chosen deliberately for component structure and employer familiarity. Cost: an npm build in the deploy path where there was none. The *functional* scope stays as the skill drew it — submit, poll, render. |
| Going public | Portfolio project, single user assumed throughout | Open signup, advertised, real users | Changes the threat model rather than the architecture: rate limits, CORS and a spending stop become load-bearing where they were previously theoretical. |

## Decision log

| Decision | Chosen | Rejected | Why |
|---|---|---|---|
| Frontend framework | React + build step | Plain HTML/CSS/JS | Component structure and familiarity, accepted as a deviation from the skill's non-goals. |
| Upstream protection | Global worker concurrency limit (1 task) | Per-submit month cap; both | Protects the dependency that cannot be bought back — an IP ban breaks the product for everyone, where a bill can be capped. Per-submit fairness deferred as a known limitation above. |
| Scaling beyond one worker | **Stay at one.** Scaling is gated on establishing the real limit with Chess.com, not on picking a mechanism | FIFO by username; DynamoDB locks; sharded queues — all deferred as unproven | Chess.com's rule is per *caller*, not per player, so "one worker per player" may be no safer than the naive version. One task is the only configuration known to comply. The mechanisms are recorded in the scaling section as tools *if* a per-player limit is confirmed — deliberately not as a plan, because an earlier draft of this file named FIFO as the answer on an assumption the API's wording does not support. |
| Hosting | S3 (private) + CloudFront + ACM | S3 website hosting alone | Website endpoints are HTTP-only, and Cognito requires HTTPS callbacks outside localhost. The login flow would not work. |
| Signup | Open | Invite-only | Advertising it; open signup is the normal shape for a public tool. |

---

## Watch for

- **The ACM certificate must be in `us-east-1`.** Everything else is `ap-southeast-1`. CloudFront reads certs from `us-east-1` only, and this is the most common way this setup fails.
- **CORS is two things.** The preflight `OPTIONS` and the actual request both need correct headers, and a 401 response needs them too — otherwise the browser reports a CORS error where the real problem is an expired token.
- **The bucket must not be public.** Origin Access Control lets CloudFront read a private bucket. A public bucket is the old pattern and a needless exposure.
- **`prevent_user_existence_errors` is already ENABLED** (Phase 2). Keep it: it stops signup and login being used to enumerate who has an account.
- **Ingestion cost does not scale with users, but drain time does.** The bill stays trivial; the wait does not. That is the limitation recorded above, and the thing to watch once anyone actually uses this.
