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

**Consequences:** a Cognito client secret exists, so Secrets Manager is now genuinely in scope with a nameable failure mode. Two trust levels exist (verified Lichess link vs unverified Chess.com username) and what each permits is a real decision, below.

## Least-privilege IAM — auth-independent, start here

**What it is for:** the blast radius of a compromised function. The skill lists "least-privilege IAM, no wildcard policies" as a Phase 2 deliverable, and Phase 1 already built to that standard — so this is an audit and a formalisation, not a rewrite.

Verified in the Phase 1 code: submit holds `dynamodb:PutItem` + `sqs:SendMessage`, status holds `dynamodb:GetItem` only, each scoped to the exact table and queue ARNs with logs scoped to each function's own log group. The worker's task and execution roles are split. No wildcards anywhere.

- [x] **Audit every policy against the live account** — done 17 Aug 2026. All four roles pulled live and matched against Terraform; `terraform plan` clean on all four stacks, so nothing was clicked in the console. Also verified: **zero managed policies attached** to any role (the usual way `AWSLambdaBasicExecutionRole` and its `logs:*` wildcard arrives), trust policies each scoped to one service principal, no resource-based policies on the queues or ECR, and no customer-managed policies in the account at all.
- [x] **Prove a denial on purpose** — done 17 Aug 2026. status was temporarily given a `PutItem` attempt; DynamoDB returned `AccessDeniedException`, logged to `/aws/lambda/chess-cloud-status`, and a follow-up `get-item` confirmed the row was never written. Reverted, redeployed, drift-checked clean. This is the step that separates "the policy document looks right" from "IAM is enforcing it at runtime" — they are different claims.
- [x] **Does the authorizer change any role's scope?** No, and the reasoning is worth keeping: the authorizer gates the **caller** (does this request reach the Lambda at all), the execution role gates the **function** (what may this code touch once running). Two boundaries at different layers, routinely conflated. Cognito changes who may call status; it does not change the fact that status must never be able to write. Roles stay exactly as they are.

**The one `Resource: "*"` in the account is correct and is not a finding.** `chess-cloud-worker-execution` allows `ecr:GetAuthorizationToken` on `*` because it is a registry-level action — it returns a token for the whole registry, so no narrower ARN exists to scope it to. The image pull beside it *is* scoped to the exact repository ARN. Worth knowing precisely, because it is the kind of thing a naive policy scanner flags and a good answer explains.

## Secrets and configuration — now in scope

**What it is for:** keeping credentials out of source and out of environment variables. The skill lists SSM/Secrets Manager in Phase 2.

**The failure mode, named:** the Cognito app client secret, and the Lichess OAuth client registration, are credentials that mint or exchange tokens. Leaked, they let someone impersonate the app in a token exchange. That is a real secret with a real blast radius — unlike `TABLE_NAME` and `QUEUE_URL`, which are non-secret identifiers and stay exactly where they are, in plain environment variables. Moving those into Parameter Store would be motion, not security.

- [ ] Choose **Secrets Manager vs SSM Parameter Store** on cost and rotation need, and record why. SecureString parameters are free and sufficient for a static secret; Secrets Manager is ~$0.40/secret/month and earns it only if rotation is actually used.
- [ ] Store the Cognito client secret there, not in Terraform state in plaintext and not in a `.tfvars` committed by accident.
- [ ] Grant read access to **only** the function that needs it, scoped to that one secret's ARN — same standard as the rest of the IAM below.
- [ ] Confirm no secret reaches CloudWatch. Logging a token or a client secret is the classic way this leaks.

## The authorizer — the actual build

**What it is for:** rejecting unauthenticated requests at the gateway, before any Lambda runs. Phase 1 chose HTTP API partly because its built-in JWT authorizer is the slot this plugs into — that decision was made with this phase in mind.

- [ ] Cognito user pool + app client. Decide token lifetimes deliberately — short access tokens with refresh is the default worth defending.
- [ ] JWT authorizer attached to the HTTP API, issuer and audience pointing at the user pool.
- [ ] Both routes protected. Confirm the authorizer runs *before* the Lambda — an unauthenticated request should cost zero invocations.
- [ ] Map the verified `sub` claim to `userId`. This is the load-bearing detail: `PK = USER#<cognito-sub>` must key off the *verified* claim, never a client-supplied field.
- [ ] Remove or re-scope the 10 req/s throttle — it exists because the API has no auth, so revisit its purpose once it does.

## Account linking — the second half of auth

**What it is for:** proving a user owns the chess account whose games they are analysing. Cognito proves they own an account *here*; it says nothing about who they are on a chess site. Linking closes that gap where the platform allows it.

Kept in this phase deliberately: the skill assigns no phase to Chess.com ingestion, so there is no later phase that would naturally host this. Deferring it would park it indefinitely, not schedule it.

- [ ] Model linked accounts on the user item — platform, username, and a **verified** flag. Not a separate identity.
- [ ] Lichess OAuth2 PKCE link flow. No client secret by design; the returned identity is trustworthy.
- [ ] Chess.com placeholder: username stored **unverified** until OAuth approval exists. Decide whether to apply for approval now or leave it.
- [ ] **Decide what an unverified link permits.** Chess.com data is public, so "unverified still allows analysis" is defensible — but decide it on purpose and record why. Two trust levels in one system is exactly the detail that gets probed.
- [ ] Decide what happens when a user links an account someone else has already linked.

## Failure paths

The part most portfolio projects skip, and the part interviews actually probe. Phase 1 set the standard: drills, watched live, not assertions.

- [ ] **No token** → `401` at the gateway, Lambda never invoked. Confirm in the logs, not just the response.
- [ ] **Expired token** → `401`. Requires deliberately minting a short-lived one.
- [ ] **Valid token, someone else's game** → `403` or `404`, decided on purpose. Leaking existence via a `403` is a real distinction; pick one and record why.
- [ ] **Tampered signature** → rejected.
- [ ] **Token from a different user pool**, correctly signed but wrong issuer → rejected. Checking the signature is not the same as checking who signed it.
- [ ] **Abandoned OAuth link flow** — user starts a Lichess link and never returns. Confirm no half-written link is left on the user item.

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
| _(next)_ | | | |

---

## Watch for

- **Auth is the whole phase.** If the pipeline changes shape this phase, something has gone wrong. Login and linking both sit in front of the API; neither touches submit → SQS → worker → `COMPLETE`.
- **This phase is now roughly twice its original size.** That was a deliberate call, but it is the thing most likely to sprawl. Linking is *store and verify an account*, not a social graph, not a profile system, not a settings page.
- **Scope creep into chess.** Still the standing risk. PGN parsing, Stockfish, and the dashboard are later phases — Stockfish is not Phase 2 under any reading.
- **Do not add a service because the skill lists it.** The "name the failure mode" test outranks the list. Secrets Manager earned its place this phase only because a real client secret now exists — that argument does not generalise to the next service.
- **Two trust levels is a design, not an accident.** Verified Lichess links and unverified Chess.com usernames must differ on purpose, and the difference must be written down before it is implemented.
- **Know the monthly cost and what drives it.** Very few grads can; the skill calls this the interview edge. Cognito and Secrets Manager are the first things here with a per-unit price — know both.
