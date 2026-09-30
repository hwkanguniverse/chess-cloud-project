# Phase 5 — CI/CD

**Goal:** every change reaches AWS the same way, from the repo, with no long-lived keys. Today a deploy is whatever one laptop did: `terraform apply` root by root in an order held in my head, a worker image built and pushed by hand, and a drift check run when remembered. Two of this project's real failures came from exactly that gap — **a 300-game run evaluated by a four-day-old worker image** (Phase E), and **a five-minute outage from an IAM grant and its code going out in one apply** (Phase 4).

**No certification covers this.** The skill maps it to DVA "loosely". It is here because a deployed project nobody else can deploy is a demo, and because OIDC federation — trading a GitHub-signed token for short-lived AWS credentials — is the modern answer to the access key in a CI secret, and interviewers ask about it.

**The temptation here is a pipeline bigger than the project** — matrix builds, staging environments, a test suite written for coverage — **or a pipeline with more power than the laptop it replaces.** Terraform in this repo creates IAM roles, so whatever role applies it can grant itself anything. Moving that from an MFA-protected user to a workflow trigger is a real change in who can do what, and has to be decided rather than defaulted.

Previous phases: [PHASE-1.md](PHASE-1.md), [PHASE-2.md](PHASE-2.md), [PHASE-3.md](PHASE-3.md), [PHASE-F.md](PHASE-F.md), [PHASE-E.md](PHASE-E.md), [PHASE-6.md](PHASE-6.md), [PHASE-4.md](PHASE-4.md). Read them for decisions already made, and do not redo them.

**Owed from earlier phases and not this phase's work:**
- **Phase F's hosting is still blocked on choosing a domain** — CORS, the browser drills and the public launch all wait behind it. The frontend is therefore out of this pipeline's scope until it has somewhere to deploy to.
- **Going public — the site *or* the repo — first needs Phase E's global daily ceiling.** Self sign-up is on, accounts are free, and each can spend ~$2.40/day under the per-account bucket. The repo holds the live API URL and Cognito IDs, so making it public is the same launch.

Account: `961868442307` · Region: `ap-southeast-1` · IAM user: `terraform-admin` (MFA enabled)

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

*Access note: the skill is not readable from the CLI. It is exported as `aws-cert-plan.skill` (a zip containing `SKILL.md`) in `~/Downloads` and unpacked. **Updated 3 Sep 2026** to describe the project as of the end of Phase 6 — the stale "ECS + ALB + RDS, apply/screenshot/destroy" row is replaced by what was actually built, the private-subnet decision and its costing are recorded, and the apply/destroy discipline is narrowed to what bills hourly while idle. **Updated 30 Sep 2026** for the end of Phase 4: status (next is 5), the Phase 4 row, the architecture line (six Lambdas, two queues, two services, one GSI, one SNS topic), the `by-class` GSI in the data model, a "What Phase 4 settled" section, and a correction to Phase E's parallel-efficiency figure — part of its "batch tail" was duplicate evaluation. Previous version kept as `aws-cert-plan.skill.bak-20260930`. **Same day, the per-game cost was re-measured** from task lifetimes checked against the bill: ~$0.10 per 300-game player worst case, not $0.043 — see the skill's cost model.*

Run `bash scripts/check-drift.sh` after every apply.


---

## Where deployment is today

Stated first, because the gaps are specific.

- **No `.github/` at all.** The repo is on GitHub (`hwkanguniverse/chess-cloud-project`, not publicly visible) and local `main` is **11 commits ahead** of it — nothing has been pushed since Phase 6.
- **A deploy is eight manual applies.** `bootstrap` (the state bucket), then `guardrails`, `network`, `data`, `queue`, `auth`, `worker`, `api`, in dependency order via remote state. The order is known, not written down anywhere executable. Phase 4 hit it twice — queue would not plan until guardrails was applied, worker until queue was.
- **The worker ships separately, by hand, as `:latest`.** `terraform apply` does not deploy it. Phase E lost a whole run to that, and the task definition cannot say which code it runs.
- **The image is unpinned.** `apt-get install stockfish` and `pip install boto3 chess` take whatever is current. A rebuild — which CI will do far more often than I did — can silently change the engine version, and with it every evaluation the product shows.
- **No tests exist.** The only automated check is `check-drift.sh`, run by hand.
- **No secrets exist, so CI needs none.** Every Terraform variable has a default in code and there are no tfvars. OIDC is the only credential the pipeline would hold.
- **Lambda zips are built from the working copy, and `core.autocrlf=true`.** Built on this laptop the handlers have CRLF line endings; checked out on a Linux runner they have LF. **The first CI apply will redeploy all six Lambdas, and alternating laptop and CI applies would redeploy them every time.**

---

## To decide before building

Each has a real trade-off.

- [x] **Repo visibility — and therefore what GitHub will actually enforce.** *Decided: private for now — see the decision log.* On the Free plan, *private* repos get no branch protection and no deployment environments, so "apply on merge" is a habit rather than a control; they also get 2,000 Actions minutes/month. *Public* repos get both protections and unlimited minutes, but publish the code, the account ID and the alert email (none secret; the account ID is mildly sensitive). GitHub Pro is ~$4/month — twice this project's budget. **Options: public; private and accept convention; Pro.** *(Plan details to be checked against GitHub's current docs before deciding.)*
- [x] **Flow: plan on PR, apply on merge — or not?** *Decided: PRs for `terraform/` and `app/`, docs straight to `main` — see the decision log.* The skill says PRs. This is a one-person repo that has committed straight to `main` for seven phases. A PR flow is the thing interviewers recognise and makes a plan reviewable before it applies; direct pushes are honest about how the work is done. **Options: PRs for everything; PRs for `terraform/` only; push to `main` and plan-then-apply in one run.**
- [x] **How much power the apply role gets.** *Decided: `AdministratorAccess`, guarded by the trust policy — see the decision log.* Because Terraform here writes IAM, the apply role can escalate to admin whatever its policy says. **Options: `AdministratorAccess`, controlled entirely by who can assume it (the OIDC trust conditions); a hand-scoped policy (long, and breaks every phase that adds a service); a permissions boundary that every role Terraform creates must carry (real containment, more Terraform).** The plan role is separate and read-only either way.
- [x] **Does the laptop keep applying?** *Decided: CI only; the laptop is break-glass — see the decision log.* Two sources of applies means the CRLF churn above, and two actors racing one state lock. **Options: CI only, with `terraform-admin` kept as break-glass; both, with line endings pinned so the zips match.**
- [x] **How the worker is deployed.** *Decided: tagged with the git SHA, deployed through `image_tag`, image pinned — see the decision log.* **Options: CI builds on changes under `app/worker/`, tags the image with the git SHA and passes it as `image_tag`, so the task definition names its code and a rollback is a revert; keep `:latest` and force a new deployment.** Whichever — pin Stockfish and the Python packages, or say why not.
- [ ] **What "test" means here.** The skill's pipeline is *test → build → ECR → deploy*, and there are no tests. Name the failure each check would catch before writing any: `terraform fmt`/`validate`, `tsc`, a Python compile, or real unit tests for the pure functions (selection, phase buckets, summaries).
- [ ] **Where the drift check runs.** After every CI apply (replaces "run it by hand"), on a nightly schedule (catches console changes nobody applied, costs minutes), or both.

## To build

Ordered so each piece is verifiable before the next depends on it.

- [ ] **A `ci` root, applied by hand:** the GitHub OIDC provider and the plan and apply roles. The one unavoidable chicken-and-egg — CI cannot create the role it assumes — so, like `bootstrap`, it stays a manual apply.
- [ ] **Pin line endings** with `.gitattributes`, so a Lambda zip is byte-identical whether built on Windows or Linux — then a break-glass laptop apply does not redeploy every function.
- [ ] **Push the repo**, and a first workflow that only *plans*, with the read-only role. Seen producing the expected result: no changes, or exactly the CRLF Lambda diff and nothing else.
- [ ] **The apply workflow**, running the roots in dependency order.
- [ ] **The worker image**: built, pushed and deployed by the pipeline, in whatever form is decided above.
- [ ] **`check-drift.sh` in the pipeline**, and **extended to assert the OIDC trust conditions** — a trust policy loosened to `repo:*` would keep every workflow working perfectly, the failure that looks like success.

## What must not change

Carried forward because the temptation to revisit them does not go away.

- [ ] **Ingestion stays pinned at `max_capacity = 1`.** The Chess.com constraint is unchanged, and it is still the one risk money cannot undo.
- [ ] **Scale-to-zero stays.** `MinCapacity == 0` per service, drift-checked. Eight idle evaluators are ~$108/month against a ~$2 budget.
- [ ] **No ALB, no NAT, no RDS.** Phase 6 priced all three and rejected them.
- [ ] **Both services stay in the purpose-built VPC**, with the task security group holding zero inbound rules. Drift-checked as of Phase 6.
- [ ] **The Phase 4 alert path stays whole** — both DLQ alarms and the Lambda errors alarm, actions enabled, to a confirmed subscription. Drift-checked.
- [ ] **No long-lived AWS keys in GitHub.** Not as a fallback, not temporarily.

## Failure paths to drill

Same standard as every prior phase: watched live, not asserted.

- [ ] **The trust policy refuses what it should** → a workflow on a non-`main` ref (or a PR, for the apply role) tries to assume the apply role and is denied. A trust policy only ever seen accepting is untested.
- [ ] **A broken change stops before it applies** → a deliberate `terraform validate` or plan failure, and nothing reaches AWS.
- [ ] **An apply fails partway through the roots** → what state is each root left in, and does re-running converge?
- [ ] **Two pushes close together** → two runs against one state. Does the concurrency setting or the S3 lock stop them, and which one wins?
- [ ] **A worker change deploys the code it claims to** → the running task names the image, the image contains the change. The Phase E check, automated.
- [ ] **Phase 4's IAM-then-code outage** → does the pipeline's apply order reproduce it, and if so what prevents it?

## Cost controls

- [ ] **Actions minutes.** A private repo has 2,000/month free; eight roots of `init` + `plan` is a few minutes per run. Know the per-run figure after the first real run.
- [ ] **ECR storage**, if images are tagged per commit: each is ~hundreds of MB. A lifecycle policy keeping the last few is the obvious bound.
- [ ] **Re-run `scripts/check-drift.sh` after each apply.**
- [ ] **Workers back to zero after every drill.**

---

## Deviations from the roadmap

Earlier phases' deviations are in their own files and still stand.

| Deviation | Skill says | We did | Why |
|---|---|---|---|
| *(none yet)* | | | |

## Decision log

Earlier decisions are in [PHASE-1.md](PHASE-1.md), [PHASE-2.md](PHASE-2.md), [PHASE-3.md](PHASE-3.md), [PHASE-F.md](PHASE-F.md), [PHASE-E.md](PHASE-E.md), [PHASE-6.md](PHASE-6.md) and [PHASE-4.md](PHASE-4.md), and remain binding.

| Decision | Chosen | Rejected | Why |
|---|---|---|---|
| Repo visibility | **Private for this phase; public deferred to the launch** | Public now; public after building a global daily cap; GitHub Pro | Nothing in Phase 5 needs public. The control over who can deploy is the OIDC trust policy, which works identically on a private repo; branch protection would only guard a one-person repo from its owner; 2,000 minutes/month is hundreds of runs. **A history scan (30 Sep, all 86 commits) found no credentials** — no keys, tokens, state, plans or tfvars — but did find the live API URL, Cognito pool and client IDs in `web/.env.example`. With self sign-up on and accounts free, **publishing the repo is going public**: each account can spend ~$2.40/day, and the global daily ceiling Phase E named for that is not built. So visibility is decided together with that ceiling and Phase F's launch — a portfolio decision, not a CI one |
| Deploy flow | **Changes under `terraform/` or `app/` go through a PR:** CI plans every root and posts the plan on the PR; merging to `main` applies. Docs commit straight to `main`, and the workflows' path filters mean they trigger nothing | PRs for everything; push to `main` and plan-then-apply in one run | The review that matters is reading a plan *before* it applies — some changes replace a resource, and a replaced table is 83k games gone. Pushing straight to `main` turns the plan into a log read after the fact. PRs for doc edits would add steps where nothing can break. On a private repo this is a habit, not a rule GitHub enforces. Known gap: the apply re-plans at merge rather than applying the reviewed plan file — acceptable with one author |
| Apply role's power | **`AdministratorAccess`, with the control in the trust policy:** only this repo, only `main`, only the apply workflow. Proven by a drill that a non-`main` ref is refused, and drift-checked so the conditions cannot loosen. A separate read-only role plans PRs | A hand-scoped policy; a permissions boundary on every role Terraform creates | Terraform here writes IAM, so any role that applies it can grant itself admin — a hand-scoped list is admin with extra steps, and breaks each time a phase adds a service. The same trap as Phase 6's per-service security groups: a name claiming a tighter control than the rules deliver. A boundary is the real containment and the stronger interview answer, but means a boundary on ~10 roles and fiddly IAM conditions — more than a one-person project's risk warrants. The cost, stated: the trust policy is now the account's front door, with no MFA behind it |
| Who applies | **CI only.** `terraform-admin` (MFA) stays as break-glass — the pipeline broken, GitHub down — and for the two roots CI cannot manage: `bootstrap` (the state bucket) and `ci` (the role CI assumes). Line endings pinned with `.gitattributes` regardless | Both, with line endings pinned so the zips match | Two deploy paths mean some changes skip the PR and the plan review, which is the gap this phase exists to close. Two actors also race one state lock. Pinning line endings anyway keeps an emergency laptop apply from redeploying all six Lambdas over invisible CRLF differences |
| Worker deploy | **CI builds on changes under `app/worker/`, tags the image with the git SHA and passes it to Terraform as `image_tag`**, so the task definition names its exact code. ECR lifecycle policy keeps the last few. **Image pinned:** base image to a specific Debian release, Python packages to versions | Keep `:latest` and have CI push it | `:latest` fixes "forgot to push" but not "which code ran?" — the task definition cannot say, and a push mid-run gives tasks started later different code from those already running, so one run is evaluated by two versions. A SHA makes the running code visible in the console, a version change happen only at an apply, and a rollback a revert. Pinning because `python:3.13-slim` follows Debian's current release, so a rebuild can move Stockfish by major versions and change every evaluation with no code change — and CI rebuilds far more often than I did |

---

## Watch for

- **CI is about to become the most privileged identity in the account, and it has no MFA.** Whatever can trigger the apply workflow can do what the apply role can. The trust conditions are the control; treat them like one.
- **Pin third-party actions to a commit SHA, not a tag.** A tag can be moved to different code after you trusted it; this is the supply-chain version of `:latest`.
- **Never `pull_request_target` for anything that touches AWS.** It runs with the base repo's credentials on code from the PR.
- **The plan role reads state, and state holds every attribute of every resource.** No secrets exist today; that is a reason to keep it true, not to stop checking.
- **`terraform apply` does not deploy the worker** — until this phase makes it. Until then, the Phase E rule stands: build, push, and verify the code is in the image.
- **Deploying is a distinct test from running.** A green pipeline says Terraform succeeded, which Phase E and Phase 4 both showed is not the same as the system working.
- **Failures surface where the component lives, not where you look first** — an assume-role denial appears in the workflow log and CloudTrail, not in anything this project's alarms watch.
- **Prove a new check fails, not just that it passes.**
- **`aws logs` needs `MSYS_NO_PATHCONV=1` in Git Bash on Windows.**
