# Phase 6 — VPC

**Goal:** stop running in the default VPC. Every task this project runs today lands in the account's default VPC on its public subnets, because that was the cheapest thing that worked and nothing yet justified otherwise. This phase builds the network deliberately — VPC, subnets, route tables, security groups, task roles — and moves the workers into it.

**This is the first numbered phase since 3, and the first that maps to a certification.** Phases F and E were product work and carried no cert. Phase 6 is **SAA** networking (plus SOA), and the material lands by building it rather than by reading it.

**The temptation here is to build a diagram, not a network.** Private subnets, NAT Gateways and VPC endpoints are the textbook picture, and most of that picture costs real money for a workload that makes exactly two kinds of outbound call. The rule below — name the failure mode — decides what gets built, and a NAT Gateway at ~$32/month against a ~$2 budget has to earn its place like anything else.

Previous phases: [PHASE-1.md](PHASE-1.md), [PHASE-2.md](PHASE-2.md), [PHASE-3.md](PHASE-3.md), [PHASE-F.md](PHASE-F.md), [PHASE-E.md](PHASE-E.md). Read them for decisions already made, and do not redo them.

**Two things are owed from earlier phases and are not this phase's work:**
- **Phase F's hosting is still blocked on choosing a domain** — CORS, the browser drills and the public launch all wait behind it. It does not block Phase 6.
- **Phase E's per-player claim is deployed but never drilled live.** Every stored player is fully evaluated, so nothing reaches the claim. A third player would exercise it.

Account: `961868442307` · Region: `ap-southeast-1` · IAM user: `terraform-admin` (MFA enabled)

---

## How we work on this

Unchanged since Phase 1, and still the point of the exercise. This project is a learning exercise; the deliverable is understanding, not a finished stack — a working stack I cannot explain is a failed phase.

**Claude writes the code. I make the decisions, after I understand them.**

- **Explain first, then write.** Before adding a service: what problem it solves in *this* app, what breaks without it, what it costs. Then I decide, then you write it.
- **Ask, don't assume.** Any choice with a real trade-off — service selection, retry policy, storage layout, what counts as done — is mine. Present the options and what each costs, then wait.
- **Name the failure mode** a service exists to handle here. If the honest answer is "real systems use it", it gets cut — that rule cut S3 in Phase 3, the automated spending stop in Phase F, and account verification in Phase E.
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

*Access note: the skill is not readable from the CLI. It is exported as `aws-cert-plan.skill` (a zip containing `SKILL.md`) in `~/Downloads` and unpacked. **Updated 2 Sep 2026** to describe the project as of the end of Phase E — the "Stockfish lands here in Phase 4" inconsistency is fixed, the engine's measured cost and depth findings are in, and the build order now records what is complete.*

Run `bash scripts/check-drift.sh` after every apply.

---

## Where the network is today

Stated first, because this phase is a migration rather than a greenfield build — and what exists is deliberate, not accidental.

- **Both Fargate services run in the account's default VPC**, on its public subnets with a public IP, in one security group with **no inbound rules**. See the comment at the top of [terraform/worker/main.tf](terraform/worker/main.tf).
- **Nothing routes to the workers.** They are queue consumers: they poll SQS and are never a destination. That is why there is no ALB, which the skill already records as saving ~$17/month over the naive design.
- **There is no NAT Gateway.** A public subnet with a no-inbound SG gets outbound internet for free; NAT costs ~$32/month to buy a property this workload does not currently need.
- **Outbound traffic is exactly two kinds:** Chess.com over HTTPS (ingestion only — the evaluator makes *zero* upstream requests), and AWS APIs (DynamoDB, SQS, ECR, CloudWatch Logs).

**The honest question this phase has to answer:** what does a purpose-built VPC give this project that the default one does not? "Real systems use it" is not an answer — that is the rule that cut S3, the spending stop and verification. Candidate answers to test, not to assume:

- The default VPC is **shared, implicit state** nobody declared. It is not in Terraform, so `check-drift.sh` cannot assert anything about it, and a change to it is invisible to this project.
- Its subnets **auto-assign public IPs by default**, which is a property inherited rather than chosen.
- It is the one piece of networking in the stack that **cannot be rebuilt from code**, which contradicts the project's own no-console-clicking rule.

That is the case to make or reject before writing any Terraform.

---

## To decide before building

Each of these has a real trade-off and a real price, so each is a decision rather than a step.

- [ ] **Does this project need private subnets at all?** The textbook answer is yes; the workload's answer might be no. Private subnets need either a NAT Gateway (~$32/mo, 16× the whole budget) or a full set of VPC endpoints (interface endpoints ~$7/mo *each* for ECR, ECR-DKR, Logs, SQS, STS; DynamoDB and S3 gateway endpoints are free). Both are more than this project spends in total. **Options: keep public subnets with tight SGs; go private with endpoints; go private with NAT.** The skill already leans public-plus-tight-SGs — confirm or overturn it deliberately.
- [ ] **What is the actual security gain?** A no-inbound security group already means nothing can reach the tasks. Private subnets defend against a *misconfigured SG*, not against the current one. Worth naming what the second layer buys before paying for it.
- [ ] **Gateway endpoints are the exception and may be worth it regardless.** DynamoDB and S3 gateway endpoints are **free**, and keep table traffic off the public internet even from a public subnet. If the answer to the above is "stay public", these may still be the right call — cheap, and they change the traffic path rather than just the diagram.
- [ ] **Multi-AZ or single-AZ?** Subnets in two AZs cost nothing extra and let ECS place a task when one AZ is unavailable. This is close to free and probably right, but say so rather than inheriting it.
- [ ] **Does the VPC live in its own Terraform root?** The existing split is by lifecycle — `auth/` separate from `api/` because a user pool must never be destroyed by a code change. A VPC has a similarly long lifecycle, and moving the workers into it creates a cross-root dependency that has to be wired somehow (remote state, data sources, or variables).

## To build

Ordered so that nothing is destroyed before its replacement is proven — **the sequencing lesson from Phase E's migration: reader first, then data.**

- [ ] **The VPC itself**, in Terraform, with a chosen CIDR and subnets across two AZs.
- [ ] **Security groups written as rules, not as one bucket.** Today there is a single `worker` SG shared by both services. Ingestion talks to Chess.com; the evaluator talks to nothing upstream. That is a genuine difference the SGs could express.
- [ ] **Task roles reviewed while the networking moves.** The skill lists "task roles" as part of this phase, and Phase E's four IAM bugs are the argument for looking again — `Query`, `BatchWriteItem`, `SendMessageBatch` and a log group scope, each of which failed only at runtime.
- [ ] **Move one service first, verify, then the other.** Ingestion and evaluation are independent; moving both at once means a failure has two candidate causes.
- [ ] **`check-drift.sh` extended** to assert whatever this phase decides is load-bearing — the same way it already asserts `MinCapacity == 0` per service and `MaxCapacity == 1` scoped to ingestion.
- [ ] **Verify the outbound paths still work** after the move: a real ingestion run reaching Chess.com, and a real evaluation run reaching DynamoDB, SQS, ECR and Logs. **ECR is the one to watch** — a task that cannot pull its image fails before any application code runs, so it looks like a platform fault rather than a networking one.

## What must not change

Carried forward from earlier phases because the temptation to revisit them does not go away.

- [ ] **Ingestion stays pinned at `max_capacity = 1`.** The Chess.com constraint is unchanged, and it is still the one risk money cannot undo. Networking work is not a licence to revisit it.
- [ ] **Scale-to-zero stays.** `MinCapacity == 0` per service, drift-checked. Eight idle evaluators are ~$108/month against a ~$2 budget.
- [ ] **No ALB.** Nothing routes to a queue consumer. If a load balancer appears in this phase, something has gone wrong.
- [ ] **The evaluator's exemption from the `MaxCapacity` assertion stays scoped.** It is deliberately the one service whose ceiling is a tuning knob — and it is capped at **8** to match the Fargate Spot vCPU quota, because a ceiling above a quota is a deadlock rather than a ceiling.

## Failure paths to drill

Same standard as every prior phase: watched live, not asserted. "No errors" is not evidence — Phase E recorded four bugs that hid behind healthy status.

- [ ] **A task that cannot reach ECR** → what does it look like, and is it distinguishable from an application fault?
- [ ] **A task that cannot reach DynamoDB or SQS** → the failure mode a missing endpoint or route produces, and whether it reaches the DLQ looking like something else.
- [ ] **An AZ with no capacity** → does ECS place the task in the other one?
- [ ] **The move itself is reversible** → confirm the old path still works until the new one is proven.

## Cost controls

- [ ] **Know the monthly cost of the network before applying it.** This phase is the one where a single resource can cost more than the entire project — NAT Gateway ~$32/mo, interface endpoints ~$7/mo each. The budget alarm is two emails and does not stop spend.
- [ ] **Re-run `scripts/check-drift.sh` after each apply.**
- [ ] **Workers back to zero after every drill.**

---

## Deviations from the roadmap

Earlier phases' deviations are in their own files and still stand.

| Deviation | Skill says | We did | Why |
|---|---|---|---|
| *(none yet)* | | | |

## Decision log

Earlier decisions are in [PHASE-1.md](PHASE-1.md), [PHASE-2.md](PHASE-2.md), [PHASE-3.md](PHASE-3.md), [PHASE-F.md](PHASE-F.md) and [PHASE-E.md](PHASE-E.md), and remain binding.

| Decision | Chosen | Rejected | Why |
|---|---|---|---|
| *(none yet)* | | | |

---

## Watch for

Carried from Phase E because they are about how this project goes wrong, not about the engine.

- **A textbook diagram is not a justification.** This is the phase most likely to buy architecture for its own sake, and the price tags here are the largest in the project. Name the failure mode.
- **`terraform apply` does not deploy the worker.** The Lambdas are repackaged from source; the worker ships as a container tagged `:latest`. After changing anything under `app/worker/`, build and push the image and verify the code is in it before trusting a run.
- **Check the quota before raising any ceiling.** A `max_capacity` above the Fargate Spot vCPU quota leaves tasks permanently unplaceable and blocks scale-in, with every component reporting success.
- **Deploying is a distinct test from running.** Phase 3 found three runtime-only IAM bugs and Phase E found four more. Networking has the same property: a route or endpoint that is wrong fails only when traffic tries to use it.
- **Sequencing: the reader before the data.** Phase E migrated a player before deploying the reader that understood the new shape, and its games briefly read as zero.
- **Shared config is an assumption with a shelf life.** The player route inherited a timeout sized for "one DynamoDB call" and kept it after it began paginating a whole partition.
- **`aws logs` needs `MSYS_NO_PATHCONV=1` in Git Bash on Windows**, and `filter-log-events` has silently returned nothing where `get-log-events` returned 622 lines. Read streams directly.
