# Phase 2 — Checklist

**Goal:** put an identity in front of the pipeline. Today anyone holding a game id can read that game; by the end of this phase the API knows *who is asking*, refuses everything else, and knows which chess accounts that user has linked.

**Auth is completed in this phase, not split across two.** Cognito login and account linking ship together — see the auth model below for why they are separable problems but a single phase.

**The rule that makes this phase work:** the pipeline does not change. No new services in the data path, no touching the worker, no chess. Phase 1's plumbing stays exactly as it is and gains a front door with a lock. If a change would alter how a message flows from submit to `COMPLETE`, it belongs to a later phase.

Phase 1 is complete and its checklist is preserved in [PHASE-1.md](PHASE-1.md) — read it for the decisions already made, do not redo them.

Account: `961868442307` · Region: `ap-southeast-1` · IAM user: `terraform-admin` (MFA enabled)

---

## How we work on this

Unchanged from Phase 1, and still the point of the exercise. This project is a learning exercise; the deliverable is understanding, not a finished stack — a working stack I cannot explain is a failed phase.

**Claude writes the code. I make the decisions, after I understand them.**

- **Explain first, then write.** Before adding a service: what problem it solves in *this* app, what breaks without it, what it costs. Then I decide, then you write it.
- **Ask, don't assume.** Any choice with a real trade-off — service selection, token lifetime, claim mapping, IAM boundary — is mine. Present the options and what each costs, then wait.
- **Explain the failure mode a service exists to handle** in *this* app before adding it. If the honest answer is "real systems use it," it gets cut.
- **Tick items off in this file as they are completed.** A stale checklist is worse than none.
- **Record decisions in the log below** — choice, alternative, reason. The reasoning is what fades.
- **Say when I am wrong, and why.** Agreeing with a bad call to be pleasant wastes the exercise.
- **Keep this file high level.** Purpose of each service and the decisions behind it. Implementation detail lives in the code, not here.

## Staying faithful to the roadmap

The `aws-cert-plan` skill is the source of truth for architecture and cost decisions. This file is a working checklist derived from it — **it does not override it.** Where they disagree, the skill wins and this file gets fixed.

Rules that keep the two from drifting apart:

- **Do not restate the skill's reasoning here** — reference it. Duplicated rationale is what drifts.
- **Re-read the skill at the start of each phase**, and before any decision it already covers. Do not work from memory of it.
- **Any deviation goes in the Deviations table below, with a reason**, or it does not happen.
- **The skill is the constraint list, not a suggestion.** Load-bearing for Phase 2: least-privilege IAM with no wildcards, secrets in SSM/Secrets Manager rather than env files, and the "name the failure mode or cut it" test.
- **If a constraint turns out to be wrong**, that is a finding — say so, and update the *skill* on the Claude account, not just this file.

*Access note: the skill is not readable from the Claude Code CLI — there is no `~/.claude/skills/` on this machine and account-level skills do not sync down. It was read this phase by exporting `aws-cert-plan.skill` (a zip containing `SKILL.md`) and unpacking it. Expect to re-export it at the start of each phase.*

Run `bash scripts/check-drift.sh` after every apply. It checks the live account against the constraints that cost real money and exits non-zero on drift. Discipline fails silently; a script does not.

---

## Where Phase 1 landed relative to the roadmap

Phase 1 overshot. It built the full pipeline shape, which means work the skill schedules for Phases 3 and 6 is already done. Recorded here so it does not get built twice — the phase numbering below stays aligned with the skill's.

**Build order is `1 → 2 → 3 → 6 → 4 → 5 → 7`.** Phase 6 is pulled ahead of 4 and 5 so the VPC/SAA material lands inside the SAA study window.

| Skill phase | Status after Phase 1 | Genuinely remaining |
|---|---|---|
| 3 — presigned S3 → SQS → worker → DLQ, idempotency | SQS, DLQ, redrive, worker, at-least-once and the idempotency argument all built and drilled | The **presigned S3 upload** path only. Per the skill, Chess.com serves monthly archives as JSON/PGN directly, so presigned upload applies to the *pasted/uploaded PGN archive* input, not to API ingestion. |
| 6 — VPC/subnets/SGs/task roles + autoscaling on SQS depth | Default-VPC public subnets, zero-ingress SG, split task/execution roles, step scaling to zero on queue depth — all live | A **custom VPC** with deliberate subnet design, if that is judged worth it over the default VPC. Currently unjustified: nothing routes inbound to the worker. |

**Cert timing is explicitly not a constraint on this project** (decided 17 Aug 2026). Whether the VPC/SAA material is learned by building it here or on Skill Builder is immaterial, so Phase 6 is not scheduled against the SAA exam window and no phase ordering is justified on cert grounds. Build order still follows the skill; the reason is coherence, not exam dates.

---

## The auth model — decided

Ids are hard to guess, which is not access control. The id format never protected anything; verifying who is asking does.

**Authentication and account linking are two separate problems**, and the phase went wrong while they were treated as one. Splitting them is what unblocked it:

- **Authentication — Cognito.** Who is this user, persistently, across sessions. A Cognito user pool owns the account; `sub` is the permanent key. `PK = USER#<cognito-sub>`.
- **Account linking — per platform, after signup.** Which chess accounts has this user proven they own. Stored as attributes on the user, not as the user's identity.

Linking is per-platform and optional, which is what removes the external dependency:

- **Lichess** — OAuth2 PKCE, open, no application or approval. Buildable today, and the link is genuinely verified.
- **Chess.com** — OAuth is approval-gated (aimed at connected-board and login integrations, timeline not ours). Until approval lands the username is stored **unverified**. The feature still works: the Published Data API is public, so analysis does not require a verified link.

**Why not the alternatives:** plain Cognito alone leaves the chess username a self-asserted claim with no path to ever verifying it. Lichess-as-login verifies the wrong thing — it proves a Lichess identity while the skill ingests from Chess.com, so the verification does not transfer. Chess.com-as-login is the only single-provider option where identity and data agree, and it is the one that can stall indefinitely on someone else's approval queue.

**Consequences:** two trust levels exist (verified Lichess link vs unverified Chess.com username) and what each permits is a real decision, below. Note that Cognito does *not* bring a client secret with it — the browser client is public and uses PKCE, so the secrets section stays empty. That was initially recorded the other way round and corrected once the client type was settled.

## Least-privilege IAM — auth-independent, start here

**What it is for:** the blast radius of a compromised function. The skill lists "least-privilege IAM, no wildcard policies" as a Phase 2 deliverable, and Phase 1 already built to that standard — so this is an audit and a formalisation, not a rewrite.

Verified in the Phase 1 code: submit holds `dynamodb:PutItem` + `sqs:SendMessage`, status holds `dynamodb:GetItem` only, each scoped to the exact table and queue ARNs with logs scoped to each function's own log group. The worker's task and execution roles are split. No wildcards anywhere.

- [x] **Audit every policy against the live account** — done 17 Aug 2026. All four roles pulled live and matched against Terraform; `terraform plan` clean on all four stacks, so nothing was clicked in the console. Also verified: **zero managed policies attached** to any role (the usual way `AWSLambdaBasicExecutionRole` and its `logs:*` wildcard arrives), trust policies each scoped to one service principal, no resource-based policies on the queues or ECR, and no customer-managed policies in the account at all.
- [x] **Prove a denial on purpose** — done 17 Aug 2026. status was temporarily given a `PutItem` attempt; DynamoDB returned `AccessDeniedException`, logged to `/aws/lambda/chess-cloud-status`, and a follow-up `get-item` confirmed the row was never written. Reverted, redeployed, drift-checked clean. This is the step that separates "the policy document looks right" from "IAM is enforcing it at runtime" — they are different claims.
- [x] **Does the authorizer change any role's scope?** No, and the reasoning is worth keeping: the authorizer gates the **caller** (does this request reach the Lambda at all), the execution role gates the **function** (what may this code touch once running). Two boundaries at different layers, routinely conflated. Cognito changes who may call status; it does not change the fact that status must never be able to write. Roles stay exactly as they are.

**The one `Resource: "*"` in the account is correct and is not a finding.** `chess-cloud-worker-execution` allows `ecr:GetAuthorizationToken` on `*` because it is a registry-level action — it returns a token for the whole registry, so no narrower ARN exists to scope it to. The image pull beside it *is* scoped to the exact repository ARN. Worth knowing precisely, because it is the kind of thing a naive policy scanner flags and a good answer explains.

## Secrets and configuration — correctly empty, so far

**What it is for:** keeping credentials out of source and out of environment variables. The skill lists SSM/Secrets Manager in Phase 2.

**There is still no secret in this app, and that is the finding.** The client is a browser page, so the app client is public and Cognito generates no secret for it — verified live: `ClientSecret` is absent on `chess-cloud-web`. PKCE covers the code exchange instead. A confidential client *would* have a secret, but choosing one to create work would mean shipping a secret to a browser, which is not a secret at all.

Everything the functions receive — `TABLE_NAME`, `QUEUE_URL`, region, and now the user pool id and client id — is a non-secret identifier. The client id appears in the login URL by design. Plain environment variables are the correct home for all of it; Parameter Store would be motion, not security.

- [x] **Conclusion recorded: we did not need it.** By the skill's own "name the failure mode or cut it" test, an empty section is the right outcome, not a gap. Do not re-add it out of habit.
- [ ] Revisit **only** if Lichess linking turns out to need a stored client credential. Decide then, on rotation need, and record why.

## The authorizer — the actual build

**What it is for:** rejecting unauthenticated requests at the gateway, before any Lambda runs. Phase 1 chose HTTP API partly because its built-in JWT authorizer is the slot this plugs into — that decision was made with this phase in mind.

- [x] **Cognito user pool + app client** — built 17 Aug 2026 in `terraform/auth/`, a separate root from `api/` because the two have opposite lifecycles: handlers redeploy constantly, a user pool holds real accounts and carries `deletion_protection`. Lite tier, MFA off, email as username, 1h access / 30d refresh, code flow only, SRP only (no `USER_PASSWORD_AUTH`, which would put the raw password on the wire). Hosted UI live; JWKS endpoint serving RS256 keys.
- [x] **JWT authorizer attached**, issuer and audience pointing at the pool. Audience is the app client id, so a token minted for another client of the same pool is rejected here.
- [x] **Both routes protected**, and the *"costs zero invocations"* claim proven rather than assumed: three rejected requests produced **0 `START` records** in either function's log group. The gateway rejects before the integration runs.
- [x] **Verified `sub` mapped to `userId`.** `PK = USER#<cognito-sub>`, read from `requestContext.authorizer.jwt.claims` — a field only API Gateway can populate, and only after validating the signature. Confirmed live: a submit sending `{"username": "hikaru"}` stored `PK = USER#593a550c-…`, with `hikaru` demoted to an attribute.
- [x] **Throttle kept, re-scoped.** It no longer guards against anonymous hammering — the authorizer does that for free at 401. What remains is a blast-radius limit on an *authenticated* caller: a runaway polling loop or one compromised account still cannot run up a Lambda bill.

**Consequence worth noting:** the composite id lost its username field. It was `username-timestamp-gameId`; the partition now comes from the token, so it is `timestamp-gameId` and only has to be unique within a user. The worker takes `userId` from the SQS message body rather than parsing it out of the id.

## The product correction — analysis is public and shared

**Surfaced 17 Aug 2026, while scoping linking.** The unit of work is a *player's profile*, not a single game: the point of the app is seeing skill across many games. Analysis results are public — anyone may view anyone's profile — and re-analysing a player someone else has already analysed is pure waste.

That reverses this phase's earlier `PK = USER#<cognito-sub>` decision, and the reversal is correct. That decision was argued on enforcing *ownership* by the key. If profiles are public there is no ownership to enforce, so it was solving a problem this product does not have. The skill agrees: it treats Chess.com's monthly archives as "one queue message per user-month, not per game" and builds its cost story on ETags making re-analysis nearly free — both of which assume analysis is keyed by chess account.

**Two separate things, previously tangled:**

| | Key | Visibility |
|---|---|---|
| **Analysis** | `PK = PLAYER#<platform>#<username>`, `SK = ARCHIVE#<yyyy-mm>` | Public, shared, deduplicated |
| **User** | `PK = USER#<cognito-sub>`, `SK = PROFILE` / `LINK#<platform>` | Private to that user |

A user's links are a private pointer *into* shared analysis. Two users analysing the same player hit one partition; the second reuses the result.

- [x] **Re-keyed analysis to `PLAYER#<platform>#<username>` / `ARCHIVE#<yyyy-mm>`** — done 17 Aug 2026. Submit, status, the worker and the queue message body all moved together. Verified live: a submit stored `PLAYER#chesscom#hikaru` / `ARCHIVE#2026-08`.
- [x] **Id is now `platform/username/yyyy-mm`**, carried as three path segments (`GET /analysis/{platform}/{username}/{archive}`) so no escaping is needed. It is fully derived from the request, which is what lets two users' identical requests land on the same item.
- [x] **Dedup proven live.** The insert is conditional on `attribute_not_exists(PK)`, so a repeat submit returns `200 {"deduplicated": true}` and enqueues nothing — confirmed by the queue holding exactly **one** message after two identical submits. A check-then-write would have raced here; the conditional write cannot.
- [x] **`requestedBy` is stored but never returned.** Attribution for debugging, not API surface — returning it would leak one user's activity to another on otherwise public data.
- [ ] **Worker image not yet rebuilt.** `worker.py` is updated for the new key but Docker was unavailable, so the running image still expects the old message shape. The service is scaled to zero and both queues are empty, so nothing is broken — but the first submit after this needs a rebuilt image or it will fail to the DLQ.
- [ ] **Decide whether public reads should keep requiring a token.** Currently they do. The argument for keeping it is attribution and rate-limiting; the argument against is that the data is public and Chess.com serves it unauthenticated anyway. Not urgent, but it is now an inconsistency rather than a decision.

**The ownership drills this invalidates.** "Valid token, someone else's game → 404" tested a boundary that no longer exists: analysis is public, so there is no cross-user read to prevent. It is struck from the failure paths below rather than quietly left passing — it would still return 404 for an *absent* player, but that tests spelling, not authorisation.

## Account linking — the second half of auth

**What it is for:** proving a user owns the chess account whose games they are analysing. Cognito proves they own an account *here*; it says nothing about who they are on a chess site. Linking closes that gap where the platform allows it.

Kept in this phase deliberately: the skill assigns no phase to Chess.com ingestion, so there is no later phase that would naturally host this. Deferring it would park it indefinitely, not schedule it.

**Built after the re-key**, so it lands on the corrected model rather than being written twice.

- [x] **Linked accounts modelled as one item per link** — `PK = USER#<sub>`, `SK = LINK#<platform>`, carrying username, `verified`, `linkedAt`. Listing is one query on the `SK` prefix. Built in `app/handlers/link.py` with its own Lambda and role.
- [x] **Lichess OAuth2 PKCE flow built.** No client secret and, as it turns out, **no registration either** — Lichess accepts an arbitrary `client_id` for public PKCE clients, verified against the live authorize endpoint. `POST /link/lichess` returns an authorize URL; Lichess responds `303` to it, so the request is well-formed. Scope is deliberately empty: reading the account's own username needs no permission, and asking for more would widen the blast radius of a leaked token for nothing.
- [x] **Chess.com placeholder built.** `POST /link/chesscom` stores the username with `verified: false` and says so in the response. No approval applied for — the feature works without it, so applying would be optimism rather than need. Revisit only if a feature appears that genuinely requires a verified Chess.com link.

**The callback is the only unauthenticated route in the API, and that is not a gap.** Lichess redirects the user's *browser* back, and a redirect carries no `Authorization` header — there is no token to present. The OAuth `state` stands in for it: 32 bytes of entropy this API generated and stored against the user's own partition moments earlier, so holding a valid one is itself proof of who is returning. Single-use (deleted on success), 10-minute expiry. Drilled: a forged state returns "link expired" and **zero outbound calls to Lichess** — an attacker cannot even use it to make this API hammer someone else's server.
- [x] **What an unverified link permits: full analysis.** The Published Data API is public and unauthenticated, so analysing those games needs no proof of ownership — blocking would trade a working feature for a guarantee the data does not require. The `verified` flag still exists, because a *verified* link is what a future feature (say, "my stats" vs "a player I looked up") would key off.
- [x] **Duplicate links: allowed, because analysis is shared.** Once analysis is keyed by player rather than by user, two users linking the same account is not duplication — they point at one shared partition. Uniqueness enforcement would add a GSI to prevent something that costs nothing.

## Failure paths

The part most portfolio projects skip, and the part interviews actually probe. Phase 1 set the standard: drills, watched live, not assertions.

All run live 17 Aug 2026 against the deployed API. Tokens were obtained by a real SRP login, not minted locally — `ADMIN_USER_PASSWORD_AUTH` is disabled on the client, which the drill confirmed by failing on it first.

- [x] **No token** → `401`, and **0 Lambda invocations** in the logs. Same for `POST` and for a syntactically invalid token.
- [x] **Expired token** → `401`. Client validity was temporarily dropped to the 5-minute minimum, a token minted, confirmed `200` while valid, then re-sent after expiry for a `401`. Reverted to 1 hour afterwards and verified live.
- [x] ~~**Valid token, someone else's game** → `404`~~ — **struck.** Passed when analysis was keyed per user, then the product decision made analysis public and shared, which removed the boundary this drill tested. Kept visible rather than deleted: a drill that stops being meaningful is a change in the threat model, and silently dropping it would hide that.
- [x] **Tampered signature** → `401`. Also drilled the sharper version: payload rewritten to claim a **different `sub`** with the original signature attached — i.e. an attempt to impersonate another user — rejected.
- [x] **Token from a different user pool** → `401`. A genuinely valid, correctly-signed, unexpired token from a throwaway second pool. Proves the authorizer checks *who signed it*, not merely that it is signed. Throwaway pool deleted afterwards.
- [x] **Abandoned OAuth link flow** → nothing half-written. Two Lichess flows were started and never completed; the table held two `OAUTH#<state>` items and **no `LINK#lichess`**. The link only exists once Lichess vouches for the username, so an abandoned flow leaves inert state that DynamoDB TTL sweeps on `expiresAt`.
- [x] **Expired state is rejected by the handler, not by the sweep.** TTL deletion is asynchronous and can lag ~48h, so a stale item may still be present. Drilled by planting an item expiring in 2001: the callback returned "link expired" and made no token exchange. Trusting TTL for correctness would have been the bug here.
- [x] **Forged state** → "link expired", and **0 outbound calls to Lichess** confirmed in the logs.

## Cost controls

- [ ] Confirm Cognito stays free at this scale — the free tier is 50,000 MAU for user-pool sign-ins, which a personal project will not approach. Verify the current figure rather than trusting this line.
- [ ] If Secrets Manager is chosen over SSM SecureString, that is ~$0.40/secret/month — small, but it is the first recurring charge this project has taken on. Justify it or use Parameter Store.
- [ ] Re-run `scripts/check-drift.sh` after each apply.
- [ ] Month-to-date spend still ~zero via the Budgets API — free to query, unlike Cost Explorer at $0.01/call.

---

## Deviations from the roadmap

| Deviation | Skill says | We did | Why |
|---|---|---|---|
| Phase 3 worker | Lambda worker | Fargate worker | Already reconciled *in* the skill — the chess adjustment makes the worker core infrastructure, not a throwaway lab. |
| Phase 1 scope | Phase 1 is API GW + Lambda + DynamoDB + budget | Also built SQS, DLQ, Fargate worker, autoscaling | The skill's own Phase 1 brief ("fake worker, full pipeline shape") required it. Pulls work forward from Phases 3 and 6; recorded in the table above so it is not built twice. |
| Phase 2 scope | "Cognito or JWT, least-privilege IAM, SSM/Secrets Manager" | Also account linking (Lichess OAuth + Chess.com placeholder) | The skill treats identity as one deliverable, but proving *chess* account ownership is a second problem it does not address — it never assigns Chess.com ingestion a phase at all. Linking has no later home, so it ships here. Roughly doubles the phase. |
| Phase 6 timing | Pulled ahead of 4 and 5 so the VPC lab lands in the SAA study window | Keep the `1 → 2 → 3 → 6` order, but on coherence grounds only | The skill's stated reason for the reordering is the exam window, and cert timing is explicitly not a constraint here (17 Aug 2026). Same order, different justification — recorded so the reasoning does not get re-derived from the skill's premise. |
| Pipeline changed inside Phase 2 | This file's own rule: "the pipeline does not change" this phase | Re-keyed analysis to `PLAYER#…`, which touches submit, worker and the queue message | A product decision surfaced mid-phase: analysis is public and shared, so keying it per user was wrong. Building linking on the old key would have meant writing it twice. Chosen deliberately over deferring to Phase 3, with the cost acknowledged — Phase 2 no longer holds the "auth only" line, and the ownership drills it invalidates must be replaced rather than dropped. |
| _(next)_ | | | |

## Decision log

Phase 1's decisions are in [PHASE-1.md](PHASE-1.md) and still binding — this table records Phase 2 onwards only.

| Decision | Chosen | Rejected | Why |
|---|---|---|---|
| Phase 2 file structure | Keep skill numbering; record Phase 1's overshoot | Fold leftover Phase 3/6 work into Phase 2 | Renumbering would drift this file from the skill, and the skill is the source of truth. The overlap table carries the same information without breaking the mapping. |
| Auth route | Cognito for login + per-platform account linking | Lichess-as-login; Chess.com-as-login; plain Cognito alone | Authentication and linking are separate problems; treating them as one was what made the decision look blocked. Cognito owns the durable identity, linking proves chess ownership per platform. Lichess-as-login verifies the wrong thing given Chess.com ingestion — the verification does not transfer. Chess.com-as-login is the only coherent single-provider option and is approval-gated, so it can stall indefinitely. |
| Chess.com link, unverified | Store the username unverified; still allow analysis | Block until OAuth approval | The Published Data API is public, so analysis genuinely does not need a verified link. Blocking would trade a working feature for a guarantee the data does not require. Revisit if approval lands. |
| Auth scope | Complete auth in Phase 2, linking included | Ship Cognito in Phase 2, defer linking | The skill assigns no phase to Chess.com ingestion, so there was no later phase for linking to land in — deferring would have parked it, not scheduled it. Cost is roughly double the original Phase 2 scope. |
| Cert timing as a constraint | Ignore it; sequence on coherence | Pull Phase 6 forward to sit inside the SAA window | The material can be learned here or on Skill Builder and the exam date does not depend on the build. Removing this unblocks phase ordering from an external clock. |
| IAM denial drill target | Write to a dedicated `DRILL#iam` key | Mutate a real game item | The table was empty, so a dedicated key proved the same thing with no path to touching real data. It also inverts the evidence usefully: a *broken* boundary leaves a visible stray item rather than silently passing. |
| `ecr:GetAuthorizationToken` on `*` | Keep it | Try to scope it to the repository ARN | It is a registry-level action with no resource-level ARN — `*` is the only valid value AWS accepts. Scoping is applied to the image-pull actions beside it. Recorded so it is not "fixed" later by someone reading the wildcard rule literally. |
| `terraform-admin` holds `AdministratorAccess` | Leave it this phase, note it | Tighten to a scoped deploy policy now | Out of scope: the skill's constraint is on the app's roles, which are clean. It is the widest thing in the account and has MFA. A real exercise if wanted later — not Phase 2 work, but recorded so it is a decision rather than an oversight. |
| Cognito app client type | Public, no secret (PKCE) | Confidential client with a secret | The client is a browser page and a secret shipped to a browser is not a secret. This is what empties the Secrets Manager section — the phase briefly assumed the opposite before the client type was settled. |
| `terraform/auth/` as its own root | Separate state from `api/` | Add Cognito to the existing api stack | Opposite lifecycles. Handlers redeploy on every code change; a user pool holds real accounts and must not sit one bad destroy away from code being iterated on. Same reasoning that already splits `data`/`queue`/`worker`. |
| Login auth flow | SRP + refresh only | Also enable `USER_PASSWORD_AUTH` | `USER_PASSWORD_AUTH` sends the raw password to the API. SRP proves knowledge of it without transmitting it, and nothing here needs the simpler flow. |
| Cognito tier | Lite | Essentials / Plus | Lite covers password sign-in, hosted UI and JWT issuance — the whole phase. The higher tiers add threat protection at a per-MAU price with no failure mode here to justify it. |
| Password policy | 12 chars, no symbol requirement | Symbols required | Length beats character-class rules for real entropy; symbol requirements mostly produce "Password1!" and a sticky note. |
| Partition key after auth | `PK = USER#<cognito-sub>` | `PK = USER#<chess-username>` + owner attribute | Keeps both of the skill's access patterns working with no GSI — "list my games" is just a query on the caller's partition. Ownership is enforced by the key itself rather than by a check after the read. Cost: two users analysing the same player store separate items, which is acceptable while the payload is small. |
| Not-your-game response | `404` | `403` | With the subject in the key, a miss is the natural outcome and leaks nothing. `403` would mean deliberately building a cross-user read in order to refuse it — adding the capability the boundary exists to prevent. |
| Composite id format | `timestamp-gameId` | Keep `username-timestamp-gameId` | The username is no longer part of the key, so carrying it in the id would be decorative and misleading. The worker gets `userId` from the message body instead. |
| Throttle after auth | Keep at 10 req/s, re-scoped | Remove it | Its original job (anonymous hammering) is now the authorizer's, done for free at 401. Its remaining job is real: bounding one authenticated caller's blast radius — a runaway poll loop or a compromised account. |
| Analysis partition key *(supersedes the row above)* | `PK = PLAYER#<platform>#<username>` | `PK = USER#<cognito-sub>` | The earlier row argued the sub-keyed model on enforcing ownership by the key. Analysis turns out to be **public and shared**, so there is no ownership to enforce and the argument does not apply. Keying by player is what makes "no point re-analysing" true: two users asking for the same player reuse one partition. Matches the skill's archive-per-user-month chunking and its ETag cost story. |
| Link storage shape | One item per link, `SK = LINK#<platform>` | One `PROFILE` item holding a `linkedAccounts` map | A map needs read-modify-write, so two link flows in two tabs can silently drop one another's link. One item per link is a single `PutItem` with no prior read, and listing is a query on the `SK` prefix. |
| Unverified link permissions | Full analysis allowed | Block until verified; or allow but degrade | Chess.com's Published Data API is public, so ownership proves nothing the data does not already give. Blocking would disable the main input path while waiting on an approval queue that is not ours. |
| Duplicate links | Allowed | Block, or block only for verified links | Once analysis is keyed by player, two users linking the same account share one partition rather than duplicating anything. Enforcing uniqueness would need a GSI to prevent a non-problem. |
| Re-key before linking | Re-key analysis first, then build linking | Linking first, re-key in Phase 3 | Linking written against the old key would have to be rewritten immediately after. Cost: Phase 2 breaks its own pipeline rule — recorded in the deviations table. |
| OAuth callback host | API-hosted `GET /link/lichess/callback` | Client-side exchange in a future frontend | There is no frontend yet and the skill caps it at "a page that posts and polls". An API-hosted callback is testable today; a client-side one would have left the exchange unbuilt and the abandoned-flow drill notional. |
| Callback route unauthenticated | Yes, guarded by OAuth `state` | Try to require a JWT on the callback | A browser redirect cannot carry an `Authorization` header, so requiring one would make the flow impossible. The `state` is server-generated, single-use, short-lived and stored against the user — it is the credential for this hop. |
| Pending OAuth state storage | Same table, `SK = OAUTH#<state>`, DynamoDB TTL on `expiresAt` | A separate short-lived table | One more item type with a TTL versus a second table to manage. The TTL is also what makes the abandoned-flow guarantee structural rather than a cleanup job. |
| Lichess client registration | None — arbitrary `client_id` | Register an application first | Verified live: Lichess accepts any `client_id` for public PKCE clients and responds `303`. Pre-registration would have been ceremony with no effect. |
| Chess.com OAuth approval | Do not apply | Apply now so approval is in flight | The feature works unverified because the Published Data API is public. Applying would be optimism, not need — revisit if a feature ever requires a *verified* Chess.com link. |
| _(next)_ | | | |

---

## Watch for

- **Auth is the whole phase.** If the pipeline changes shape this phase, something has gone wrong. Login and linking both sit in front of the API; neither touches submit → SQS → worker → `COMPLETE`.
- **This phase is now roughly twice its original size.** That was a deliberate call, but it is the thing most likely to sprawl. Linking is *store and verify an account*, not a social graph, not a profile system, not a settings page.
- **Scope creep into chess.** Still the standing risk. PGN parsing, Stockfish, and the dashboard are later phases — Stockfish is not Phase 2 under any reading.
- **Do not add a service because the skill lists it.** The "name the failure mode" test outranks the list. Secrets Manager earned its place this phase only because a real client secret now exists — that argument does not generalise to the next service.
- **Two trust levels is a design, not an accident.** Verified Lichess links and unverified Chess.com usernames must differ on purpose, and the difference must be written down before it is implemented.
- **Know the monthly cost and what drives it.** Very few grads can; the skill calls this the interview edge. Cognito and Secrets Manager are the first things here with a per-unit price — know both.
