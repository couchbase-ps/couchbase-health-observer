# Handoff Log

Running progress so any agent (or human) can continue. Newest entry on top. Update after each step.

## State

- **Branch:** `main` (SDK per-service phase merged; was `observer-sdk-health`)
- **Phase:** implementing the SDK per-service health detector (`pkg/svchealth`) from the plan.
- **Plan:** `Couchbase/Clients/Emirates/MCA/Observer/20260619 SDK per-service health detection plan.md` (vault).
- **Done:** repo bootstrap, compose, AGENTS/CLAUDE; Tasks 1-4 green (types, prober, Compute, gocb prober).
- **Done:** SDK per-service detector COMPLETE (Tasks 1-7, e2e green). Observer deploys in compose and reports correct per-service / global health through auto-failover.
- **Next:** wrap the branch; future phases (state machine + K8s actuator + active mode) are separate.

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

Root cause: a leftover host process (a `go run ./cmd/svchealthcheck` bound to `couchbase://localhost`, which cannot reach the cluster's internal node addresses) was LISTENING on host port 8080 and intercepting every `curl localhost:8080`, always answering DOWN. The container / compose / image were correct throughout (distroless/static works fine). Fixes: killed the stray process; `test/e2e.sh` now (1) runs `compose down` first to release Docker's own 8080 forward, then guards against any remaining non-Docker listener on 8080, and (2) parses the GLOBAL status with `jq -r .status` instead of a greedy sed that grabbed the last per-service status. e2e now PASSES.

Lesson for any agent: if the observer reports DOWN unexpectedly, check `lsof -nP -iTCP:8080 -sTCP:LISTEN` for a stray host process before debugging the SDK.

## Phase 2 (2026-06-22): failover actuation — branch `observer-failover-actuation`

Build the active path on top of the svchealth detector:
- [x] state machine (`pkg/state`): sustained-DOWN FailoverDelay, reset on healthy, fires once, no auto-failback
- [ ] actuator (`pkg/actuator`): K8s ConfigMap connstring swap + Deployment rollout-restart (client-go), behind an interface + fake-clientset test.
- [ ] active mode: poll loop wiring detector -> state machine -> actuator; observe vs active modes.
