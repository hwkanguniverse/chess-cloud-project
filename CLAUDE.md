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
- [x] **Security group: one, not two — and the split was proposed and rejected on inspection, 3 Sep 2026.** `sg-034bdf25741449b9b` (`chess-cloud-tasks`) in the new VPC: **zero ingress**, egress 443 only. Verified live — `"Ingress": []`.

  **The split looked like least privilege and was not.** Ingestion talks to Chess.com and the evaluator makes zero upstream requests, so a group each seemed obviously right. But the rule you would write is identical either way: the evaluator still needs ECR, CloudWatch Logs and SQS, none of which has a free gateway endpoint, all on large changing AWS ranges — so its "restricted" egress is still 443 to `0.0.0.0/0`. Two identical rule sets under a name claiming one is tighter is **worse than one honest group**: a control that looks like it enforces something and does not, which is the pattern Phase E kept finding behind healthy status. Revisit only if interface endpoints ever exist (~$28/mo, already rejected).

  **The no-ingress rule is the control that matters**, and it is what made private subnets unnecessary — nothing routes to a queue consumer, so with no inbound rule the public subnet is irrelevant to exposure. That is the line to defend in review, not the subnet placement.

  Renamed from `worker` to `tasks`: the old name read as one service and was shared by two.
- [ ] **Task roles reviewed while the networking moves.** The skill lists "task roles" as part of this phase, and Phase E's four IAM bugs are the argument for looking again — `Query`, `BatchWriteItem`, `SendMessageBatch` and a log group scope, each of which failed only at runtime.
- [x] **Move one service first, verify, then the other.** **Both moved and verified 3 Sep 2026. The default VPC is no longer referenced by this project, and the old `chess-cloud-worker` SG is destroyed — 0 ENIs remain in `vpc-01d8f504ac1cdfa25`.**

  Verified by running it, not by reading the plan: task ENI `10.0.23.20` in `vpc-03261b9da88bf8920`, subnet `...c923899d`, SG `chess-cloud-tasks`. A real message produced `fetching chesscom/theohwk/2024-01 (conditional)` → `unchanged, skipping` — which exercises **every** outbound path at once: ECR and S3 to pull the image, Logs to write that line, SQS to receive, DynamoDB to read the stored ETag, and Chess.com over HTTPS to get the 304. DLQ empty, drift clean, service back to zero.

  **The migration itself was a one-line, in-place change** — `0 to add, 1 to change, 0 to destroy`, swapping three default subnets for two and the SG. No task was recreated, because both services were already at zero.

  **A test-harness bug, not a networking one, and worth recording as a near-miss.** The first drill message was hand-written and omitted `id`, which `worker.py` requires; the worker logged `failed, leaving for retry/DLQ: 'id'`. For a moment that read as "the move broke ingestion" — the failure mode this phase warned about, where a networking fault and an application fault look alike. It was neither: the message was malformed. **A hand-rolled test message is not the contract**; the real producer is the submit Lambda. Purged and re-sent correctly.

  **The evaluator followed and was verified the same way**: ENI `10.0.22.102` in the new VPC, a real game evaluated end to end — `done GAME#2020-11#5780873839: acpl=163 blunders=3`, written back as `evalDepth 18`. Stockfish ran to full depth, so the AWS-API paths (ECR, Logs, SQS, DynamoDB) all work for the CPU-bound service too. It is the simpler of the two to move: **zero upstream requests**, so there is no Chess.com path to prove.

  **Cleanup was a third, separate apply.** Only once both services were verified did the default VPC data sources and the old SG come out — `0 to add, 0 to change, 1 to destroy`, checked first against `describe-network-interfaces` to confirm nothing still held the group. Three applies rather than one, each independently reversible, which is the whole point of the sequencing.
- [x] **`check-drift.sh` extended** — three new checks, 3 Sep 2026. Building a VPC because the default one is *undeclared state nothing can assert on*, and then asserting nothing about it, would have moved that gap rather than closed it.

  1. **The task SG has zero inbound rules.** The one check here guarding a security property rather than a cost: this absence is what made public subnets defensible, and a single console click would end it silently.
  2. **Both services are in the purpose-built VPC's subnets.** The important one — a service reverting to the default VPC would keep working *perfectly*, since that is where it ran until today, so nothing but this check would ever surface it.
  3. **Both gateway endpoints exist.** They are free, which means nothing pressures them to exist — the usual reason a free thing quietly disappears. S3 is on the ECR image-pull path, so losing it breaks task starts rather than being cosmetic.

  **Each was proved to fail, not just to pass.** A check only ever seen passing is untested: all four negative cases were forced (SG absent, VPC absent, services in the wrong subnets, endpoints absent) and each flagged and exited 1.
- [ ] **Verify the outbound paths still work** after the move: a real ingestion run reaching Chess.com, and a real evaluation run reaching DynamoDB, SQS, ECR and Logs. **ECR is the one to watch** — a task that cannot pull its image fails before any application code runs, so it looks like a platform fault rather than a networking one.

## What must not change

Carried forward from earlier phases because the temptation to revisit them does not go away.

- [ ] **Ingestion stays pinned at `max_capacity = 1`.** The Chess.com constraint is unchanged, and it is still the one risk money cannot undo. Networking work is not a licence to revisit it.
- [ ] **Scale-to-zero stays.** `MinCapacity == 0` per service, drift-checked. Eight idle evaluators are ~$108/month against a ~$2 budget.
- [ ] **No ALB.** Nothing routes to a queue consumer. If a load balancer appears in this phase, something has gone wrong.
- [ ] **The evaluator's exemption from the `MaxCapacity` assertion stays scoped.** It is deliberately the one service whose ceiling is a tuning knob — and it is capped at **8** to match the Fargate Spot vCPU quota, because a ceiling above a quota is a deadlock rather than a ceiling.

## Failure paths to drill

Same standard as every prior phase: watched live, not asserted. "No errors" is not evidence — Phase E recorded four bugs that hid behind healthy status.

- [x] **A task that cannot reach ECR** → **drilled 3 Sep 2026, and yes — it is unmistakable, but only if you look in the right place.** Staged by removing the default route (`drill_break_egress`, a variable in `terraform/network/` defaulting to `false`, so a plain `terraform apply` is the restore).

  ```
  ResourceInitializationError: unable to pull secrets or registry auth: The task
  cannot pull registry auth from Amazon ECR: There is a connection issue between
  the task and Amazon ECR. Check your task network configuration. ... dial tcp
  13.251.117.42:443: i/o timeout
  ```

  **The message names the cause outright** — "connection issue", "check your task network configuration", a routable IP and `i/o timeout`. No guessing required.

  **What makes it distinguishable from an application fault is the absence of evidence, not the message.** `stopCode` is `TaskFailedToStart`, **no new log stream is created at all**, and the **DLQ stays empty** — the container never ran, so it never received a message, never failed one, and never wrote a line. An application fault is the mirror image: the task reaches `RUNNING`, logs a traceback, and the message retries into the DLQ. *No logs plus an empty DLQ plus a task that never reached `RUNNING`* is the signature.

  **The trap is where it surfaces.** Nothing appears in CloudWatch Logs, because logs are where a *running* container writes. It appears in **ECS service events**, which is the place nobody thinks to look first — the same lesson as Phase E's execution-role bug, which failed outside the container and only the service events explained it.

  **Recovery verified by running, not by reading the route table:** a real game evaluated end to end afterwards — `evalDepth 18, acpl 194, blunders 9`.
- [x] **A task that cannot reach DynamoDB or SQS** → **partly answered by the ECR drill, and not staged separately.** Removing the default route breaks *every* AWS API at once, and the task died before reaching SQS or DynamoDB at all — which is itself the finding: **the image pull fails first, so a broken route can never present as a DynamoDB or SQS fault.** Staging it in isolation would mean breaking only the gateway-endpoint routes, and the honest reason not to is that the failure would arrive as a boto3 timeout inside a running container, retry three times, and reach the DLQ — a path Phase 3 and Phase E have already drilled twice under other causes.
- [x] **An AZ with no capacity** → **cannot be staged, and saying so is the honest outcome.** Spot capacity is not something this account can exhaust on demand. What *is* verified is that the precondition holds: two subnets in `ap-southeast-1a` and `1b`, both associated to the route table, and both offered to each service — so ECS has somewhere else to place a task. Whether it does is AWS's behaviour to demonstrate, not this project's.
- [x] **The move itself is reversible** → **answered by construction rather than by a drill.** The migration was three independently reversible applies — ingestion, then the evaluator, then cleanup — and the old path stayed live throughout: the default VPC's subnets and SG were only deleted after both services were verified in the new VPC. Reverting at any point before that was a one-line change.

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
