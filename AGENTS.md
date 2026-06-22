# couchbase-health-observer — Agent Guide

Read this first. It is the single source of truth for working in this repo so you do not have to read everything. Keep it current when you change structure, conventions, or scope.

## What this project is

An **Observer** for Couchbase that detects cluster health and (in later phases) drives automated multi-region failover. Built for the Emirates **MCA replacement** engagement.

Health detection has two possible signal paths (see the durable wiki page "Cluster Health Signal Detection"):
- **SDK per-service** (`pkg/svchealth`) — SDK `ping()` reachability per service, global = worst of the app's *critical* services. **This is the path being implemented now.**
- **Cluster-API** (`pkg/clusterhealth`) — REST `/pools/default` + quorum-majority aggregation (UP/DEGRADED/DOWN). Sibling detector, **not yet implemented**.

The full Observer (later phases): health detector → anti-flap state machine (`FailoverDelay`) → REST `/health` API (`observe` mode) → Kubernetes actuator (ConfigMap connstring swap + `rollout restart`) → `active` mode. Failover automated, **failback manual**.

## Health model (SDK path)

- A service is **DOWN if any of its endpoints is unreachable**, **UP** only if all reachable. After auto-failover a node vanishes from the cluster map, so ping reads UP (cluster absorbed it).
- **Global** status = `DOWN if any critical service is DOWN, else UP`. `critical` is per-app config (e.g. `["kv"]` or `["kv","query"]`). Non-critical services still appear in the JSON for observability.
- No `DEGRADED` in the SDK path (the SDK cannot see failover state). The "don't react to transient blips" behaviour lives in the **consumer** (a delay / `FailoverDelay`), not in the health snapshot.
- Endpoint `/health/couchbase` returns the detailed JSON report; HTTP 503 when global is DOWN, else 200.

## Layout

```text
pkg/svchealth/        SDK per-service health detector (types, prober, Compute, HTTP handler)
cmd/svchealthcheck/   server exposing /health/couchbase
deploy/compose/       5-node Couchbase EE 8.0.1 harness (copied from couchbase-health-signal-lab) for integration tests
docs/                 (reserved)
HANDOFF.md            running progress log — READ THIS to see what is done and what is next
```

## Conventions

- Go 1.22+, module `github.com/couchbaselabs/couchbase-health-observer`.
- **TDD**: write the failing test first, run it red, implement, run it green, commit. Small focused files, one responsibility each.
- Dependencies behind **interfaces** with mocks (e.g. `Prober`) so logic is unit-testable without a cluster.
- **Frequent commits**, one logical step each. **Rebase, never merge** (linear history).
- Integration tests are build-tagged `//go:build integration` and need the compose cluster up.

## Workflow

- Work on a **feature branch**, never directly on `main`. Integrate by **rebase, never merge** (linear history).
- The authoritative spec is the plan + design in the Obsidian vault (paths below). Treat the SDK per-service plan as the spec for the health detector.
- **Per step:** write the failing test, run it red, implement the minimum, run it green, then **update `HANDOFF.md`**, **commit** (one logical step), and report what was done and how to verify it before moving on.
- Do not implement many steps in one go; keep each step independently testable and validated.
- If the **superpowers** skills are installed, drive the work with them: `executing-plans` (or `subagent-driven-development`) to execute the plan task-by-task, `test-driven-development` per unit, and `finishing-a-development-branch` when a phase completes.

## Build, test, run

```bash
go test ./...                                  # unit tests (no cluster needed)
# integration (needs the cluster):
docker compose -f deploy/compose/docker-compose.yml up -d   # ~90s to init + load travel-sample
go test -tags=integration ./...
go run ./cmd/svchealthcheck --conn couchbase://localhost --critical kv   # serve /health/couchbase
```

## Source design docs (Obsidian vault)

- Plan being executed: `Couchbase/Clients/Emirates/MCA/Observer/20260619 SDK per-service health detection plan.md`
- Observer overall design: `.../20260617 Observer implementation design.md`
- Health-signal findings (durable): `Couchbase/wiki/Architecture Review/Cluster Health Signal Detection.md`

## Continuing the work

Read **HANDOFF.md** for the current state and the exact next step. Update it as you finish each step.
