# couchbase-health-observer — Agent Guide

Read first. Single source of truth for this repo, so you skip reading everything. Keep current when structure, conventions, or scope change.

## What this project is

**Observer** for Couchbase. Detects cluster health and (later phases) drives automated multi-region failover. Built for Emirates **MCA replacement** engagement.

Health detection has two signal paths (see durable wiki "Cluster Health Signal Detection"):
- **SDK per-service** (`pkg/svchealth`) — SDK `ping()` reachability per service, global = worst of app's *critical* services. **Path being implemented now.**
- **Cluster-API** (`pkg/clusterhealth`) — REST `/pools/default` + quorum-majority aggregation (UP/DEGRADED/DOWN). Sibling detector, **not yet implemented**.

Full Observer (later phases): health detector → anti-flap state machine (`FailoverDelay`) → REST `/health` API (`observe` mode) → Kubernetes actuator (ConfigMap connstring swap + `rollout restart`) → `active` mode. Failover automated, **failback manual**.

## Health model (SDK path)

- Service **DOWN if any endpoint unreachable**, **UP** only if all reachable. After auto-failover a node vanishes from cluster map, so ping reads UP (cluster absorbed it).
- **Global** = `DOWN if any critical service DOWN, else UP`. `critical` is per-app config (e.g. `["kv"]` or `["kv","query"]`). Non-critical services still appear in JSON for observability.
- No `DEGRADED` in SDK path (SDK cannot see failover state). "Don't react to transient blips" lives in the **consumer** (a delay / `FailoverDelay`), not in the health snapshot.
- Endpoint `/health/couchbase` returns detailed JSON report; HTTP 503 when global DOWN, else 200.

## Layout

```text
pkg/svchealth/        SDK per-service health detector (types, prober, Compute, HTTP handler)
cmd/svchealthcheck/   server exposing /health/couchbase
deploy/compose/       5-node Couchbase EE 8.0.1 harness for the compose detector stack
deploy/kind/          kind + official Couchbase Helm switch stack
deploy/aws/           distributed-quorum AWS aggregation infra (Terraform): monitoring TG + quorum alarm + SNS
test/<stack>/         per-stack tests, each independently runnable: test/compose, test/kind, test/aws
HANDOFF.md            running progress log — READ THIS to see what is done and what is next
```

## Conventions

- Go 1.22+, module `github.com/couchbaselabs/couchbase-health-observer`.
- **TDD**: failing test first, run red, implement, run green, commit. Small focused files, one responsibility each.
- Dependencies behind **interfaces** with mocks (e.g. `Prober`) so logic is unit-testable without a cluster.
- **Frequent commits**, one logical step each. **Rebase, never merge** (linear history).
- **Commit convention: gitmoji** (not Conventional Commits). Subject = `<emoji>(scope) #<issue>: <desc>` (scope and `#issue` optional), e.g. `✨(svchealth) #1: per-service rollup`, `🐛(eks-demo) #6: ...`, `📝 #5: ...`, `🎉 bootstrap`. Map: ✨ feature, 🐛 fix, 📝 docs, ✅ tests, ♻️ refactor, ⚡️ perf, 👷 CI, 🐳 docker/build, 🔧 tooling/config, 🎉 project init, 💥 breaking. `cliff.toml` groups these for the changelog (git-cliff); releases are cut by pushing a `vX.Y.Z` tag (see `.github/workflows/release.yml`).
- Integration tests build-tagged `//go:build integration`, need compose cluster up.
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
```

## Source design docs (Obsidian vault)

- Plan being executed: `Couchbase/Clients/Emirates/MCA/Observer/20260619 SDK per-service health detection plan.md`
- Observer overall design: `.../20260617 Observer implementation design.md`
- Health-signal findings (durable): `Couchbase/wiki/Architecture Review/Cluster Health Signal Detection.md`

## Continuing the work

Read **HANDOFF.md** for current state and exact next step. Update it as you finish each step.
