# Handoff Log

Running progress so any agent (or human) can continue. Newest entry on top. Update after each step.

## State

- **Branch:** `observer-kind-switch-e2e`
- **Phase:** Observer implementation plan complete through Task 12.
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
