# CLAUDE.md

The full repo rules, description, layout, conventions, and continuation guide live in `AGENTS.md`. Read it first and follow it.

@AGENTS.md

## Claude Code specifics

- This work is driven by the **superpowers** skills. Use `superpowers:executing-plans` (or `subagent-driven-development`) to execute the plan task-by-task, `superpowers:test-driven-development` for each unit, and `superpowers:finishing-a-development-branch` when a phase is done.
- The authoritative plan and design live in the Obsidian vault under `Couchbase/Clients/Emirates/MCA/Observer/`. Treat the SDK per-service plan as the spec for the health detector.
- Work on a feature branch, not `main`. Integrate by **rebase, never merge**.
- After finishing a logical step: run the tests, update `HANDOFF.md`, commit, and report to the user how they can verify it themselves before moving on.
