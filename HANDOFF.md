# Handoff Log

Running progress so any agent (or human) can continue. Newest entry on top. Update after each step.

## Commit convention + release (2026-06-24)

Adopted **gitmoji** commits (matching `ps-knowledge-hub`): `<emoji>(scope) #<issue>: <desc>`.
`cliff.toml` (git-cliff) groups them for the changelog; `.github/workflows/release.yml`
cuts a GitHub release on a `vX.Y.Z` tag. Docker image tagging: **main -> `edge` + `sha-<sha>`
(no `latest`); `vX.Y.Z` tag -> semver + `latest`** (`docker-publish.yml`, `flavor: latest=auto`).
The entire existing history was rewritten conventional -> gitmoji (force-push pending; not
yet pushed). Convention documented in AGENTS.md.

## Cold-start switch via ConfigMap reconciliation (2026-07-08, #20)

Replaced Task-12 `armed` cold-start gate (never switch before first healthy observe)
w/ **ConfigMap reconciliation**: `cmd/svchealthcheck` reads `cb-conn` once at boot; if
already == `--secondary-conn`, seeds `state.Config.AlreadySwitched=true`
(`pkg/state.Machine.switched`, was `armed`). Effect: configmap==primary + already-DOWN
at boot -> switches after `FailoverDelay` (old gate blocked forever). configmap==secondary
at boot -> adopts, logs `"adopting switched state"`, no re-switch/no roll (actuator
ConfigMap-equality idempotency, `pkg/actuator/k8s.go:30-32`, final guard either way).
`test/kind/e2e_switch.sh` gained scenarios C/D after A/B: **C** restart into already-DOWN
region-a, `cb-conn` rewound to primary -> switch + mock-app roll; **D** immediate restart,
`cb-conn` already region-b, region-a still DOWN -> adopt, no re-switch, no roll,
`"adopting switched state"` in logs. Not run live yet (slow multi-node kind bring-up) —
`bash -n` clean only.

## State

- **Branch:** `aws-quorum-infra` (path-2 AWS aggregation; centralized observer path is on `main`).
- **Phase:** Observer implementation plan complete through Task 12. Path-2 distributed-quorum AWS aggregation infra (plan 2) built.

## Parallel CI: unit + e2e on PRs (2026-07-08)

Added `.github/workflows/e2e.yml`: four e2e jobs run parallel with `ci.yml`
(unit + terraform) on every PR. Jobs: `compose-e2e`, `compose-tls-e2e`,
`kind-switch-lambda`, `kind-region-switch`. `ci.yml` unchanged (still the lean
`workflow_call` gate for publish/release). AWS e2e excluded. Concurrency guard
cancels superseded PR e2e runs.

**PR #23 validated on GitHub runners (run 2, all-green gate):** `test` (unit),
`compose-e2e` (~3m48s), `kind-switch-lambda` (~1m6s), `kind-region-switch`
(~8m46s) all PASS. e2e workflow conclusion = success; PR MERGEABLE.
- `kind-region-switch` (6 Couchbase pods) **fits a standard `ubuntu-latest`
  runner** — resource question answered, job kept. Run 1 failure was only the
  missing `couchbase-partners` helm repo; fixed in `test/kind/e2e_switch.sh` +
  `render.sh` (`helm repo add` before `helm dependency build`).
- `compose-tls-e2e` case 1 (`--tls-cert-path` → DOWN) failed on GH runners:
  `poll_status` returned the FIRST probe (a warm-up DOWN before the observer
  settled over TLS), not the expected status. FIXED on main (89a2dd9,
  `🐛(compose) #19: wait for expected TLS e2e status, not first probe`) — the
  harness now waits for the expected status. Branch rebased onto that fix and
  `continue-on-error` removed, so `compose-tls-e2e` is a blocking gate again. All
  four e2e jobs now green + blocking.

## Distributed-quorum path 2: AWS aggregation infra (2026-06-24)

CBSE-22993 path-2 actuation. Reuse the observer health endpoint (observe-mode fleet) instead of a per-app Spring starter, so plan 1 (Spring starter) is skipped. This pass = plan 2 only (infra up to SNS); the switch Lambda (plan 3) is deferred to `cmd/switch-lambda`, reusing `pkg/actuator`.

- `deploy/aws/` Terraform: monitoring-only target group (`/health/couchbase`, 200 healthy / 503 unhealthy, no listener); metric-math quorum alarm (`unhealthy/(unhealthy+healthy) >= quorum_threshold` for `sustained_periods`, `treatMissingData=notBreaching`, no `ok_actions`); SNS topic. Outputs: TG arn, SNS arn, alarm name.
- `deploy/aws/k8s/`: observe-mode observer fleet Deployment (N replicas, AZ topology spread) + Service; TargetGroupBinding. Probes use `/healthz` (static) so a Couchbase-DOWN keeps pods Ready/registered; only the ALB TG checks `/health/couchbase`.
- Tests live under `test/aws/localstack.sh` (asserts TG health path, alarm comparator, SNS topic). Test stacks were split into `test/{compose,kind,aws}`, each independently runnable.
- Validated: `terraform validate` + `fmt` green; LocalStack shape e2e green; **plumbing fidelity confirmed on a real AWS account**.
- **Two findings from the AWS run, now fixed in the module:**
  1. A standalone target group is not health-checked (targets read `unused`) and emits no metrics. The module now creates an **internal ALB + listener** (`alb.tf`) forwarding to the TG; the ALB carries no real traffic, it only drives health checks. New required var `subnet_ids` (>=2 AZs).
  2. ALB emits `Healthy/UnHealthyHostCount` keyed by **(TargetGroup, LoadBalancer)**; a TargetGroup-only alarm sees no data and never fires. `alarm.tf` now includes the `LoadBalancer` dimension.
- Real-AWS proof: unreachable stand-in target → `unhealthy` → `UnHealthyHostCount=1` → ratio 1.0 sustained 2 periods → ALARM → SNS → SQS message. Module applies and destroys cleanly. All sandbox resources torn down.
- **Next:** a full live demo (EKS + observer fleet + reachable Couchbase + the switch Lambda end to end).

## Full Path-2 EKS demo (Terraform, 2026-06-24)

`deploy/aws/eks-demo/` stands up the entire distributed-quorum architecture on real EKS:
VPC + EKS + node group, AWS Load Balancer Controller (IRSA), 2 Couchbase clusters via the
official Operator chart (region-a slim 3-data primary, region-b 1-data secondary), mock
app, observer fleet (ghcr image `ghcr.io/couchbase-ps/couchbase-health-observer`), reused
aggregation + switch-lambda modules, and an EKS access entry for the Lambda role. The
Lambda authenticates to EKS via `pkg/eksauth` (STS token) using `EKS_CLUSTER_NAME`.

Apply is two-phase (`-target=module.vpc -target=module.eks`, then full) because the
kubernetes/helm providers depend on the cluster created in the same config.

Two bugs found + fixed during the live apply:
- **Helm values nesting.** The `couchbase-operator` chart is installed DIRECTLY here, so
  its values must be TOP-LEVEL. Nesting them under `couchbase-operator:` (correct only for
  the kind subchart wrapper) made the chart silently use defaults: bucket named `default`
  instead of `observer`, so the observer's `--bucket=observer` found nothing -> DOWN.
- **ALB->pod security group.** EKS pod ENIs carry the cluster primary SG, not just the node
  SG, so the ALB health checks timed out until a rule was added on
  `module.eks.cluster_primary_security_group_id` (kept the node SG rule too).

Two more bugs found driving the live switch end to end:
- **In-VPC Lambda could not reach the API.** The cluster had public-only endpoint access;
  a Lambda in the private subnets timed out. Enabled `cluster_endpoint_private_access` and
  opened 443 from the lambda SG to `module.eks.cluster_security_group_id`.
- **Invalid EKS token.** The hand-rolled SDK v2 STS presign produced a token with no
  `X-Amz-Expires` (EKS -> 401 Unauthorized). Replaced `pkg/eksauth` token generation with
  the reference `sigs.k8s.io/aws-iam-authenticator/pkg/token` generator. Verified with a
  `-tags live` test (`pkg/eksauth/live_test.go`).

The workload is a real Couchbase load generator: the built-in `cbc-pillowfight` from the
`couchbase/server` image (no custom image to build/push), driving continuous KV ops
against the cb-conn cluster and echoing the connstring so the target region is visible.
**Verified end to end on real EKS**: region-a down -> quorum alarm ALARM ->
SNS -> Lambda patched cb-conn to region-b + rolled traffic-app -> ops resumed
`result=OK conn=...region-b`.

Status: left running for manual demo/testing (NOT destroyed). Drive + teardown steps in
`deploy/aws/eks-demo/README.md`.

## Distributed-quorum switch Lambda (2026-06-24)

The SNS-triggered actuation for path 2, in this repo (not a separate repo), reusing `pkg/actuator`.

- `pkg/event`: parse the SNS-wrapped CloudWatch alarm; actionable only on ALARM (OK ignored, no auto-failback). Unit tested.
- `pkg/switchhandler`: on ALARM, call `actuator.Switch`; OK/empty are no-ops. Unit tested with `actuator.Mock`.
- `cmd/switch-lambda`: `lambda.Start`, builds `actuator.K8sActuator` from env (NAMESPACE/CONFIGMAP/CONFIG_KEY/DEPLOYMENTS/SECONDARY_CONN/DRY_RUN); client via KUBECONFIG or in-cluster. Has a one-shot mode (`ONESHOT_EVENT`) for the kind e2e. Builds linux/arm64 (`bootstrap`).
- `deploy/aws/lambda/`: own Terraform root (Lambda + SNS subscription + IAM + optional VPC); takes `switch_sns_topic_arn` from the aggregation module's output. `build.sh` produces the binary; `terraform validate` green.
- Tests: kind real-switch e2e (`test/kind/switch_lambda_e2e.sh`, PASS: ALARM switches + rolls, OK no-op) and the LocalStack SNS->Lambda trigger flow (`PHASE=lambda ./test/aws/localstack.sh`, PASS, free tier). The `localstack.sh` script is phased: `PHASE=infra` (aggregation shapes, needs elbv2 tier), `PHASE=lambda` (lambda+sns, free tier), `PHASE=all` (default). Units green.
- EKS-from-Lambda auth (access entry + kubeconfig/token) is environment-specific and documented in `deploy/aws/lambda/README.md`; not exercised here (no EKS cluster).
- Branch `switch-lambda`.

## History: Observer implementation (through Task 12)

- **Plan:** `Couchbase/Clients/Emirates/MCA/Observer/20260619 SDK per-service health detection plan.md` (vault).
- **Done:** repo bootstrap, compose, AGENTS/CLAUDE; Tasks 1-4 green (types, prober, Compute, gocb prober).
- **Done:** SDK per-service detector COMPLETE (Tasks 1-7, e2e green). Observer deploys in compose, reports correct per-service / global health through auto-failover.
- **Done:** failover actuation COMPLETE (state machine, Kubernetes actuator, active mode).
- **Done:** Task 12 COMPLETE (kind + official Helm + live region switch e2e).
- **Next:** integrate `observer-kind-switch-e2e`; the Observer implementation plan has no pending tasks.

## Plan task checklist (SDK per-service)

- [x] Task 1: types (Report, ServiceHealth) + JSON shape test
- [x] Task 2: Prober interface + Mock + Probe
- [x] Task 3: Compute (per-service rollup + critical-driven global) + tests
- [x] Task 4: gocb Prober
- [x] Task 5: HTTP handler (/health/couchbase, 503/200) + tests
- [x] Task 6: cmd/svchealthcheck server
- [x] Task 7: e2e PASS (observer deployed in compose; UP -> kill node DOWN -> auto-failover UP)

## Log

- 2026-06-19: repo bootstrapped on branch `observer-sdk-health`; module `github.com/couchbaselabs/couchbase-health-observer`; gocb added; compose harness copied from `couchbase-health-signal-lab` into `deploy/compose/`; AGENTS.md, CLAUDE.md, this handoff created.

## RESOLVED (2026-06-22): the "compose observer DOWN" was a host-port-8080 squatter

Root cause: a leftover host process (a `go run ./cmd/svchealthcheck` bound to `couchbase://localhost`, which cannot reach the cluster's internal node addresses) was LISTENING on host port 8080, intercepting every `curl localhost:8080`, always answering DOWN. Container / compose / image were correct throughout (distroless/static works fine). Fixes: killed the stray process; `test/e2e.sh` now (1) runs `compose down` first to release Docker's own 8080 forward, then guards against any remaining non-Docker listener on 8080, and (2) parses the GLOBAL status with `jq -r .status` instead of a greedy sed that grabbed the last per-service status. e2e now PASSES.

Lesson for any agent: if the observer reports DOWN unexpectedly, check `lsof -nP -iTCP:8080 -sTCP:LISTEN` for a stray host process before debugging the SDK.

## Phase 2 (2026-06-22): failover actuation — branch `observer-failover-actuation`

Build the active path on top of the svchealth detector:
- [x] state machine (`pkg/state`): sustained-DOWN FailoverDelay, reset on healthy, fires once, no auto-failback
- [x] actuator (`pkg/actuator`): ConfigMap swap + rollout-restart, idempotent, dry-run, fake-clientset tested
- [x] active mode: poll loop wiring detector -> state machine -> actuator; observe vs active; KUBECONFIG/in-cluster; dry-run

## Phase 2 complete (2026-06-22): failover actuation merged to main

state machine + actuator + active-mode wiring done, all unit-tested, build green.

Previously deferred live active-mode switch e2e is complete in Task 12 below.
Compose harness remains the detector e2e; kind owns the Kubernetes actuation e2e.

## Mapping to the Observer implementation plan (20260617)

Implemented health via the **SDK per-service plan (20260619)**, not this plan's
membership/strategy detection core. So several tasks were superseded, not done verbatim.

| Task | Status |
|---|---|
| 0 Project bootstrap | done |
| 1 Core domain types (State/ClusterSnapshot/Policy) | SUPERSEDED by svchealth types (Report/ServiceHealth/Probe) |
| 2 Docker Compose CB harness | done (copied from couchbase-health-signal-lab) |
| 3 Signal-reliability spike | done earlier as the separate couchbase-health-signal-lab repo |
| 4 Health strategies (AutoFailover/ExpectedCount, UP/DEGRADED/DOWN) | SUPERSEDED by svchealth.Compute (per-service UP/DOWN) |
| 5 Collector (gocb ping + REST auto-failover) | PARTIAL: GocbProber does ping; REST/membership half intentionally absent in the SDK path |
| 6 State machine (FailoverDelay) | done (pkg/state) |
| 7 REST API + observe mode | done (/health/couchbase) |
| 8 Actuator (K8s) | done (pkg/actuator) |
| 9 Active mode wiring | done (cmd active mode) |
| 10 Dockerfile + image | done |
| 11 Compose e2e driver | done (test/compose/e2e.sh) |
| 12 Kubernetes switch e2e (kind + CAO) | done |

Net: membership/strategy detection (Tasks 1/4/5) replaced by the SDK per-service
detector by design; the spike (3) lives in the signal-lab; the live kind+CAO
active-mode switch e2e now closes the final pending capability.

## Task 12 complete (2026-06-22): kind + official Helm region switch

- kind only; no dependency on OrbStack Kubernetes.
- Dependency-only wrapper chart, following the `cao-eviction-reschedule-hook`
  example; no custom Couchbase resource templates.
- Pinned official versions: Helm chart `2.92.0`, CAO `2.9.2`, Couchbase Server
  `8.0.1`.
- `region-a` and `region-b` are separate namespaces. Each is one Helm release
  containing CAO, the admission controller, and its `CouchbaseCluster`.
- Fresh kind nodes expose an official-chart startup race: the validating webhook
  is registered while its image is still pulling, so the first cluster create
  can get `connect: connection refused`. The e2e retries only that exact failure,
  at most three Helm attempts, after waiting for the admission Deployment.
- Live e2e PASS: primary initially UP; region-a paused and its data pod deleted;
  sustained DOWN exceeded `15s`; observer changed `cb-conn` to
  `couchbase://region-b-srv.region-b.svc`; mock-app received a rollout restart
  and new pods logged the region-b connstring.
- Run: `./test/kind/e2e_switch.sh` (creates and deletes kind automatically).

## Task 12 review hardening (2026-06-22): full failover scenarios on region-a

Post-review (3 fixes; this is fix 2). region-a is now the realistic primary so the
e2e exercises the auto-failover-absorption path, matching the docker e2e:

- region-a topology: 3 data + 2 index/query nodes, bucket replica 1,
  `autoFailoverTimeout: 5s`, `autoFailoverMaxCount: 1` (values.yaml). region-b
  stays a single data node, no index/query, bucket replica 0 (region-b-values.yaml).
- observer `--failover-delay=30s` (clear margin over the 5s server auto-failover).
- e2e two scenarios: A) kill ONE region-a node -> Couchbase auto-failover absorbs it
  inside FailoverDelay -> observer must NOT switch (asserted ~45s); B) kill the rest
  -> sustained DOWN -> switch to region-b + mock-app rollout.
- Webhook retry guard broadened: retry on ANY `failed calling webhook` (the cold-node
  race shows up as `connection refused` AND `context deadline exceeded`); only a real
  `denied the request` validation fails fast.
- region-a Available/Ready waits bumped 10m -> 20m: 5-node bring-up + rebalance on
  kind exceeds 10m (the earlier 10m timeout, not a resource limit — all 5 pods schedule).
- Live e2e PASS: scenario A no-switch confirmed, scenario B switched cb-conn to
  region-b and rolled mock-app.

## Task 12 chart layout (2026-06-22): split common + per-region values

Readability refactor. `deploy/kind/couchbase-cluster` values are now three files:
- `values.yaml`: common base (install flags, image, security, bucket, auto-failover,
  `autoResourceAllocation.enabled: true` with `cpuRequests: 0.25` / `cpuLimits: 1`).
- `region-a-values.yaml`: name region-a + 3 data + 2 index/query servers.
- `region-b-values.yaml`: name region-b + single data node + bucket replica 0.

`helm_region` always layers `values.yaml` (chart default) with `$region-values.yaml`.
`autoResourceAllocation` lets the operator size pod memory from the service quotas;
CPU is pinned low because the chart default (2/4 per pod) will not fit 5+ nodes on
kind. Live e2e PASS with all pods scheduled (no Pending).

## Task 12 review hardening (2026-06-22): cold-start arm gate (fix 1)

`pkg/state` now arms only after observing the cluster healthy at least once
(`armed` flag set on any non-DOWN status). A switch can never fire before that, so
an observer that boots into an already-down primary (e.g. a pod reschedule mid-outage)
will not auto-fail-over on cold start. `TestNoSwitchUntilFirstHealthy` covers it;
existing tests now `Observe("UP")` first to arm. No auto-failback regardless.
