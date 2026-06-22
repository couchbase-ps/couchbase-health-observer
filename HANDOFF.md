# Handoff Log

Running progress so any agent (or human) can continue. Newest entry on top. Update after each step.

## State

- **Branch:** `observer-sdk-health`
- **Phase:** implementing the SDK per-service health detector (`pkg/svchealth`) from the plan.
- **Plan:** `Couchbase/Clients/Emirates/MCA/Observer/20260619 SDK per-service health detection plan.md` (vault).
- **Done:** repo bootstrap, compose, AGENTS/CLAUDE; Tasks 1-4 green (types, prober, Compute, gocb prober).
- **Next:** Task 7 — integration test against `deploy/compose` (needs docker; the first step that touches a real cluster).

## Plan task checklist (SDK per-service)

- [x] Task 1: types (Report, ServiceHealth) + JSON shape test
- [x] Task 2: Prober interface + Mock + Probe
- [x] Task 3: Compute (per-service rollup + critical-driven global) + tests
- [x] Task 4: gocb Prober
- [x] Task 5: HTTP handler (/health/couchbase, 503/200) + tests
- [x] Task 6: cmd/svchealthcheck server
- [~] Task 7: e2e — observer DEPLOYED into compose (Dockerfile + observer service), assert /health/couchbase over mapped port (host cannot reach internal nodes, so the app must run in-network)

## Log

- 2026-06-19: repo bootstrapped on branch `observer-sdk-health`; module `github.com/couchbaselabs/couchbase-health-observer`; gocb added; compose harness copied from `couchbase-health-signal-lab` into `deploy/compose/`; AGENTS.md, CLAUDE.md, this handoff created.

## OPEN BLOCKER (2026-06-22): compose-service observer reports DOWN

- The observer **image and code are validated working**: run via `docker run --network compose_couchbase compose-observer ...` it reports `status=UP, kv reachable=3` reliably, in-network, against the healthy 5-node cluster.
- The SAME image, SAME args, SAME network, run as the compose `observer` service, reports `status=DOWN, kv reachable=0` (SDK ping marks all KV endpoints unreachable). Confirmed simultaneously: a `docker run` instance UP while the compose instance DOWN.
- Ruled out: image base (distroless/static & debian-slim fail standalone too; debian:12 works standalone), CGO on/off, args, network/DNS (getent + nc to all nodes OK from in-network), network alias, container_name/endpoint reuse, GOCB_VERBOSE, cluster health (5/5 active+healthy), deps re-run.
- Root cause NOT yet found. Runtime image is debian:12. `cmd/svchealthcheck` has a `GOCB_VERBOSE=1` env toggle for SDK logging.
- Next idea: diff verbose gocb logs between a working `docker run` and the failing compose service to find where the KV connection lifecycle to cb-data-2/3 diverges; or test launching observer outside compose for the e2e.
