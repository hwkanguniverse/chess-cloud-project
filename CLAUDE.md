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

- [x] **Private subnets: no — decided 3 Sep 2026.** Subnets stay **public with a no-inbound security group**, which is what the workers already have. The failure mode private subnets defend against — something reaching the tasks — is *already impossible*: nothing routes to a queue consumer and the SG accepts zero inbound. What they would actually buy is defence against a **future misconfigured SG**, and the price for that insurance is ~$28–32/month against a ~$2 budget. See the decision log.
- [x] **There is no cheap private option, and that is what settled it.** "Private with only the free endpoints" does not exist: Fargate must reach **ECR (api + dkr) and CloudWatch Logs** to start a task at all, and neither has a free gateway endpoint. Going private means ~$28/mo of interface endpoints (ECR api, ECR dkr, Logs, SQS, STS at ~$7 each) *or* a ~$32/mo NAT Gateway. The floor is ~14× the entire project budget.
- [x] **Gateway endpoints for DynamoDB and S3: yes.** They are **free**, and they change the traffic path rather than the diagram — table traffic leaves the public internet even from a public subnet. A free improvement does not have to justify itself against the budget. S3 is included despite the project having no bucket: **ECR image layers are served from S3**, so the endpoint is on the task-start path, not decoration.
- [x] **Multi-AZ: yes, two AZs.** Costs nothing extra and lets ECS place a task when one AZ has no Spot capacity — not hypothetical here, since the evaluator runs on Spot and hit a placement ceiling in Phase E. Two rather than the default VPC's three: a third adds no availability this workload can use and is another CIDR to plan.
- [x] **The VPC gets its own Terraform root** (`terraform/network/`), consumed by `worker/` through remote state exactly as `queue/` and `data/` already are. Split by **lifecycle**, the same rule that keeps `auth/` away from `api/`: a VPC outlives the code that runs in it, and a worker redeploy must never be able to take the network with it.

## To build

Ordered so that nothing is destroyed before its replacement is proven — **the sequencing lesson from Phase E's migration: reader first, then data.**

- [x] **The VPC itself** — applied 3 Sep 2026 as `terraform/network/`, a new root. `vpc-03261b9da88bf8920`, `10.0.0.0/16`, two public subnets (`10.0.0.0/20` in `ap-southeast-1a`, `10.0.16.0/20` in `1b`), an IGW, one shared route table, and free gateway endpoints for DynamoDB and S3. **10 resources, $0/month, nothing moved into it yet** — the network is built alongside the running workers, which stay in the default VPC until the move below.

  **Verified rather than assumed**, per the phase's own standard: all four routes `active` — `local`, `0.0.0.0/0` → IGW, and **two prefix-list routes** (`pl-67a5400e`, `pl-6fa54006`) proving the gateway endpoints are in the path rather than merely created — both subnets associated to the table, and `enableDnsSupport`/`enableDnsHostnames` both `true`. `check-drift.sh` clean.

  **CIDR deliberately oversized.** A `/16` is 65,536 addresses for a workload peaking at 8 tasks. Taken anyway because a VPC CIDR **cannot be resized after creation** and unused private space costs nothing — sizing it "correctly" would optimise a free resource while creating a real future constraint. `10.x` rather than the default VPC's `172.31.x` so the two can never be confused when reading an ENI.

  **The lesson worth keeping: "public subnet" is not a subnet attribute, it is the default route to the IGW.** `map_public_ip_on_launch` without that route gives a private subnet with wasted addresses. Written as its own `aws_route` rather than inlined, so the thing doing the work is visible.
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
| Subnet placement | **Public subnets, no-inbound SG**, plus free gateway endpoints for DynamoDB and S3 | Private subnets + NAT Gateway (~$32/mo); private subnets + interface endpoints (~$28/mo); staying in the default VPC | The rule is *name the failure mode in this app*. Private subnets stop something reaching the tasks — which **already cannot happen**: nothing routes to a queue consumer, and the SG has zero inbound rules. The real gain is insurance against a *future* misconfigured SG, priced at 14–16× the entire monthly budget. Same rule that cut S3 in Phase 3, the spending stop in Phase F and verification in Phase E. **There is no cheap private option** — Fargate cannot start a task without ECR and Logs, and neither has a free gateway endpoint, so private has a hard ~$28/mo floor. The SAA material still lands: CIDR planning, subnets across AZs, route tables, IGW, SG design and task roles are all written by hand. Building NAT once as an apply/screenshot/destroy exercise stays available and costs cents. |
| Why build a VPC at all, if not for privacy | **Declared, version-controlled network in its own root** | Continuing to use the default VPC | The justification is *not* security — exposure is already zero either way. The default VPC is **undeclared, shared, implicit state**: not in Terraform, so `check-drift.sh` can assert nothing about it, its subnets auto-assign public IPs by inheritance rather than choice, and it is the one piece of infrastructure here that cannot be rebuilt from code — which contradicts the project's own no-console-clicking rule. That is a real failure mode with a $0 fix. |

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
