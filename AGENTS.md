# couchbase-health-observer — Agent Guide

Read first. Single source of truth for this repo, so you skip reading everything. Keep current when structure, conventions, or scope change.

## What this project is

**Observer** for Couchbase. Detects cluster health and (later phases) drives automated multi-region failover. Built by the Couchbase Delivery team for a customer engagement. **This repo is public: no customer name, environment name, host name or credential in any file, commit message or test fixture. Use placeholders (`app-dev`, `example.com`).**

Health detection has two signal paths (see durable wiki "Cluster Health Signal Detection"):
- **SDK per-service** (`pkg/svchealth`) — SDK `ping()` reachability per service, global = worst of app's *critical* services. **Path being implemented now.**
- **Cluster-API** (`pkg/clusterhealth`) — REST `/pools/default` + quorum-majority aggregation (UP/DEGRADED/DOWN). Sibling detector, **not yet implemented**.

Full Observer (later phases): health detector → anti-flap state machine (`FailoverDelay`) → REST `/health` API (`observe` mode) → Kubernetes actuator (ConfigMap connstring swap + `rollout restart`) → `active` mode. Failover automated, **failback manual**.

Actuator fans out: N connstring ConfigMaps + N Deployments, each ns-qualified (`ns/name`), best effort, retry until all converge. `--namespace` = default for unqualified entries.

Two actuators, picked by `--actuators` (`k8s`, `webhook`, `k8s,webhook`; empty = observe only): `k8s` = ConfigMap patch + Deployment roll; `webhook` = POST switch request (`pkg/notify`).

## Health model (SDK path)

- Service **DOWN if any endpoint unreachable**, **UP** only if all reachable. After auto-failover a node vanishes from cluster map, so ping reads UP (cluster absorbed it).
- **Global** = `DOWN if any critical service DOWN, else UP`. `critical` is per-app config (e.g. `["kv"]` or `["kv","query"]`). Non-critical services still appear in JSON for observability.
- No `DEGRADED` in SDK path (SDK cannot see failover state). "Don't react to transient blips" lives in the **consumer** (a delay / `FailoverDelay`), not in the health snapshot.
- Endpoint `/health/couchbase` returns detailed JSON report; HTTP 503 when global DOWN, else 200.

## CNG load-balancer stack

Observer = passive sensor here: observe-only, no actuators. **Envoy owns switch decision**, incl. debounce. Traffic -> CNG; health check -> **Observer**, via `health_check_config.address`, literal IP only, no DNS. Hence pinned static subnet.

Four Envoy settings default wrong for this use case:
- `retriable_statuses` must cover **503**, else unexpected status bypasses `unhealthy_threshold`, sustained-down window is no-op.
- `Cluster.close_connections_on_host_health_failure: true`, else SDK's established gRPC channel survives dead upstream, nothing fails over.
- `fail_traffic_on_panic: true`, else dual outage routes to hosts already known unhealthy.
- health-check `timeout` must exceed Observer's probe timeout: **4s here, not 2s as planned**. At 2s Observer's 503 never arrives; Envoy infers health from latency instead of reading the verdict, turning a slow-but-healthy Observer into a false failover.

Measured, reproducible from suite:
- 1 data node lost, absorbed: 5.1s gap, no switch.
- 2 data nodes lost: 26.4s gap, switch at ~+91s (Observer alive, 503 path).
- whole region gone: 103 to 120s gap across 6 runs (driver-emitted, `csv_error_window_ms`), switch at +113 to +129s across 2 runs (Observer dead, connection-failure path). Slower AND ~4x worse than 2-node case: dead host gives no TCP RST, every check burns full timeout, no partial service masks the gap. Switch-time figure, unlike gap figure, NOT driver-emitted: manual offset from harness start, unverified run-by-run. Recompute from shipped CSVs gives s4 +112s, just outside band -> undocumented derivation (offset from harness start vs node stop). Treat as approximate pending a driver-emitted version.
- both regions down: clean failure bounded by 2s KV timeout (every op takes the full ~2s to surface as error), zero hangs.
- idle client: 60s idle gap produces no errors on resume. 3600s Envoy idle timeout itself NOT exercised (60s = 1.7% of that window).
- harness `OPS_PER_SEC=20` paces loop iterations, not CSV rows: each iteration emits a `get` AND an `upsert` KV row, so realized CSV throughput is ~2x the config value, ~34-40 ops/sec, not 20.

Findings that changed the design's conclusions:
- **Existing connections do not fail back.** Envoy L4 priority routing steers new connections only; `close_connections_on_host_health_failure` evicts on unhealthy, has no healthy-again equivalent. Post-recovery: long-lived clients stay on secondary, new ones go primary. Both clusters serve different clients at once, diverge by connection age.
- **CNG's own `/health` cannot report unhealthy.** Measured 200 with all 5 region-a nodes stopped, on `couchbase/cloud-native-gateway:1.2.1`, while Observer reported DOWN. `MarkSystemUnhealthy()` has zero callers in `couchbase/stellar-gateway` on master/v1.0/v1.0.1 (only tags that repo has); 1.2.1 source itself NOT inspected, so mechanism is inferred from those branches, not confirmed for the measured image. Couchbase docs claim the opposite. Repro cheap: `test/compose-cng/lb_e2e.sh readiness`.

Closed open risks:
- standalone CNG runs against Couchbase 8.0.1, no extra flags.
- CNG survives losing the single node named by `--cb-host`, specifically when auto-failover absorbs that node's loss (not tested against a refused failover).

LB capability checklist, derived from what Envoy actually needed: health-check an arbitrary address; close established connections when a member goes unhealthy; no automatic failback; health-check timeout above the Observer's probe timeout. Note: an LB health-checking the Observer CANNOT detect a dead gateway, because the Observer reports on the cluster, not the gateway.

Auto-failover stays `timeout=30, maxCount=100`. `maxCount` is not the discriminator: quorum and replica checks are. `timeout=5` breaks `test/compose/e2e.sh`.

Design and plan: `delivery vault, CNG design and plan` and `... plan.md`.

## Layout

```text
pkg/svchealth/        SDK per-service health detector (types, prober, active-cluster prober, Compute, HTTP handler)
cmd/svchealthcheck/   server exposing /health/couchbase (+ --actuators wiring, runSwitch)
pkg/notify/           switch webhook: Event payload, Notifier iface, HTTP notifier (auth/headers/retries/TLS)
deploy/compose/       5-node Couchbase EE 8.0.1 harness for the compose detector stack
charts/couchbase-health-observer/  observer Helm chart. Single source of truth for the k8s shape. OCI to ghcr.io/couchbase-ps/charts on vX.Y.Z + .tgz on the release. version = appVersion = image tag.
hack/render-manifests.sh          regenerates deploy/k8s from the chart. deploy/k8s is GENERATED, never hand-edit. ci.yml `chart` job fails on drift.
deploy/kind/          kind + official Couchbase Helm switch stack (mock-app in default, mock-app-b in app-b, webhook-receiver for scenario E). Observer itself installs from the chart with values-examples/kind.yaml.
deploy/aws/           distributed-quorum AWS aggregation infra (Terraform): monitoring TG + quorum alarm + SNS
deploy/compose-cng/   CNG load-balancer stack: 2 regions (cng-a 5 nodes replica 1, cng-b 1 node replica 0) on shared net cng-lb-net 172.28.0.0/16, standalone CNG 1.2.1 per region, Envoy L4 passthrough, shared-SAN certs
harness/              Java SDK availability harness (couchbase2://), CSV per op with region marker
test/<stack>/         per-stack tests, each independently runnable: test/compose, test/kind, test/aws, test/helm (chart lint+render, no cluster)
HANDOFF.md            running progress log — READ THIS to see what is done and what is next
```

## Conventions

- Go 1.22+, module `github.com/couchbaselabs/couchbase-health-observer`.
- **TDD**: failing test first, run red, implement, run green, commit. Small focused files, one responsibility each.
- Dependencies behind **interfaces** with mocks (e.g. `Prober`) so logic is unit-testable without a cluster.
- **Frequent commits**, one logical step each. **Rebase, never merge** (linear history).
- **Commit convention: gitmoji** (not Conventional Commits). Subject = `<emoji>(scope) #<issue>: <desc>` (scope and `#issue` optional), e.g. `✨(svchealth) #1: per-service rollup`, `🐛(eks-demo) #6: ...`, `📝 #5: ...`, `🎉 bootstrap`. Map: ✨ feature, 🐛 fix, 📝 docs, ✅ tests, ♻️ refactor, ⚡️ perf, 👷 CI, 🐳 docker/build, 🔧 tooling/config, 🎉 project init, 💥 breaking. `cliff.toml` groups these for the changelog (git-cliff); releases are cut by pushing a `vX.Y.Z` tag (see `.github/workflows/release.yml`).
- Integration tests build-tagged `//go:build integration`, need compose cluster up.
- Chart change = assertion first in `test/helm/render.sh`, then template, then `hack/render-manifests.sh`, then commit the regenerated `deploy/k8s`. Credentials never in args: `--pass=$(CB_PASS)` + Secret env, Kubernetes expands `$(VAR)`. RBAC = ClusterRole + RoleBinding per derived namespace, never ClusterRoleBinding. Repo is public: no customer name or value in the chart.
- **Docs stay compressed.** `AGENTS.md`, `CLAUDE.md`, `HANDOFF.md` maintained in caveman-speak (terse, articles/filler dropped, code/commands/paths/tables exact). After editing any of them, recompress: `/caveman:compress <file>` if the caveman skill is available, else compress inline by hand. No `.original.md` backups — git is the history.

## Workflow

- Work on a **feature branch**, never directly on `main`. Integrate by **rebase, never merge** (linear history).
- Authoritative spec is the plan + design in the Obsidian vault (paths below). Treat SDK per-service plan as spec for the health detector.
- **Per step:** failing test, run red, implement minimum, run green, then **update `HANDOFF.md`**, **commit** (one logical step), report what was done and how to verify before moving on.
- Don't implement many steps at once; keep each step independently testable and validated.
- If **superpowers** skills installed, drive work with them: `executing-plans` (or `subagent-driven-development`) to execute the plan task-by-task, `test-driven-development` per unit, `finishing-a-development-branch` when a phase completes.

## Build, test, run

```bash
go test ./...                                  # unit tests (no cluster needed)
# integration (needs the cluster):
docker compose -f deploy/compose/docker-compose.yml up -d   # ~90s to init + load travel-sample
go test -tags=integration ./...
go run ./cmd/svchealthcheck --conn couchbase://localhost --critical kv   # serve /health/couchbase
test/compose/tls_e2e.sh                        # TLS e2e: cert-path + skip-verify + negative control
test/compose-cng/lb_e2e.sh                     # CNG LB failover: scenarios 1-8 + 10 (9 deferred) + CNG readiness evidence
test/compose-cng/lb_e2e.sh up                  # bring the LB stack up for a manual demo
```

`--log-level trace|debug|info|warn|error` (default `info`). Human-readable lines via a custom slog handler (`pkg/obslog` `NewHuman`): `HH:mm:ss.SSS LEVEL <component> <prose>` (components: observer/health/failover/actuator/cluster/probe/webhook). Events + levels + attrs unchanged, so a JSON handler is a later drop-in swap. INFO=state changes+switch actions; DEBUG=per-tick cluster detail; TRACE=per-endpoint ping. Events: `startup`, `active_config`, `adopt_switched`, `adopt_mixed`, `target_namespace_unpaired`, `liveness_window_tight`, `probe`, `health`, `cluster_detail`, `cluster_nodes`, `cluster_map[_change]`, `failover_countdown_start`, `switch_required/held/skipped`, `secondary_connect_failed`, `probe_target`, `probe_target_held`, `probe_target_unavailable`, `configmap_patch`, `deployment_roll`, `roll_only`, `roll_skipped`, `switched`, `switch_noop`, `actuation_error`, `webhook_target`, `webhook_called`, `webhook_retry`, `webhook_failed`, `webhook_dropped`, `webhook_dry_run`, `webhook_body`, `webhook_insecure`, `webhook_window_tight`, `mode_deprecated`.

`--actuators=k8s,webhook` (empty = observe only) replaces `--mode`; `--mode` deprecated one release.
Webhook flags: `--webhook-url --webhook-user --webhook-pass --webhook-header (repeatable) --webhook-timeout --webhook-retries --webhook-ca-cert --webhook-skip-verify`. Creds also via `WEBHOOK_USER`/`WEBHOOK_PASS`/`WEBHOOK_HEADER`.
Payload (`pkg/notify` `Event`): `configmaps`/`deployments` = ns-qualified `ns/name`, k8s-actuator only, omitted otherwise. No `namespace` field.
Switch latch follows whatever actuator can actually move the apps: k8s enabled -> latch = k8s result alone, webhook is then a notification only (its failure still errors + `observer_webhook_total{result=error}`, never blocks); webhook-only -> latch = webhook result (it IS the actuator) (#31, `runSwitch` in `cmd/svchealthcheck/switch.go`).

CI: `ci.yml` fast gate (fmt/vet/build/unit + terraform) runs on PRs + is
`workflow_call`ed by publish/release. `e2e.yml` runs GitHub-safe e2e in parallel
on PRs (all green, blocking, on ubuntu-latest): compose e2e, compose TLS e2e,
kind switch-lambda, kind region-switch, compose-cng-lb-e2e (60min timeout,
uploads `/tmp/cng-lb-out` as artifact `cng-lb-output` always; unvalidated
until its first green PR run). AWS e2e
(`test/aws/*`) NOT in CI (needs real AWS / LocalStack).

## Source design docs (Obsidian vault)

- Plan being executed: delivery vault, Observer folder, `20260619 SDK per-service health detection plan.md`
- Observer overall design: `.../20260617 Observer implementation design.md`
- Health-signal findings (durable): `Couchbase/wiki/Architecture Review/Cluster Health Signal Detection.md`

## Continuing the work

Read **HANDOFF.md** for current state and exact next step. Update it as you finish each step.
