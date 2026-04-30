# ADR-0006 — Storage names and boundaries

Status: Accepted
Date: 2026-04-30
Issue: `tet-db6.2` / `BD-0002`

## Context

The prior plans contain several naming choices that need to be pinned before implementation: `Tet` vs `Agent`, `.tet/` vs `.agent/`, explicit store adapters vs vague embedded storage, and product state terms such as Event Log, Artifact Store, Error Log, and Repair Queue.

Storage naming matters because it leaks into CLI commands, docs, paths, migrations, tests, screenshots, and operator muscle memory. Pick boring names early. Future-you will send a thank-you card.

Primary sources:

- `check this plans/plan 3/plan/docs/00_comparison_and_decisions.md`
- `check this plans/plan 3/plan/docs/04_data_storage_events.md`
- `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/FINAL_ULTIMATE_PLAN.md`
- `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/upgrades/12_durable_execution.md`
- `plans/ELIXIR_CLI_AGENT_GLOBAL_VISION.md`
- `plans/ELIXIR_CLI_AGENT_PHASED_IMPLEMENTATION.md`

## Decision

Use `Tet` as the internal Elixir namespace and `.tet/` as the workspace metadata directory.

Default workspace layout is conceptually rooted at:

- `.tet/tet.sqlite` for the default local SQLite database;
- `.tet/config.toml` for workspace configuration;
- `.tet/prompts/` for workspace prompt layers;
- `.tet/artifacts/` for durable artifacts such as diffs, stdout, stderr, file snapshots, prompt debug, provider payloads, remote bundles, and repair evidence;
- `.tet/cache/` for non-authoritative cache files.

Store adapters are explicit:

- `tet_store_memory` for tests and contract checks;
- `tet_store_sqlite` for default standalone local storage;
- `tet_store_postgres` for optional hosted/team/multi-node scenarios.

All persistence goes through a `Tet.Store`-style core behaviour/contract. Storage adapters map database schemas to/from core domain structs; they do not become the domain model. UI adapters do not write store rows directly.

Reserved product state terms:

- Event Log;
- Session Memory;
- Task Memory;
- Compacted Context;
- Finding Store;
- Persistent Memory;
- Project Lessons;
- Artifact Store;
- Error Log;
- Repair Queue;
- checkpoints.

Reserved domain/runtime entities may include Workspace, Session, Task, Message, ToolRun, Approval, Artifact, Event, Workflow, WorkflowStep, Hook outcome, Remote job, Repair item, and Audit entry. These entity names support the state terms; they do not replace them in product-facing docs.

Event and workflow boundaries:

- Event Log is the durable user-visible/audit timeline.
- Workflow journal/steps are the source of truth for resumable workflow side effects.
- Runtime EventBus publishes projections to CLI and optional UI subscribers.
- Phoenix PubSub may bridge events inside `tet_web_phoenix`, but it is not the runtime event store or bus.

SQLite is the default standalone store. Postgres is optional and selected by release/config for team, hosted, or future multi-node use. Phoenix must never be the reason Postgres exists; store selection is a runtime/storage decision.

## Conflict resolution

If a plan or source uses `Agent` as the root namespace, translate to `Tet` unless a later naming ADR supersedes this. Do not create a root `Agent` module.

If a plan says `.agent/`, translate to `.tet/`.

If a plan says “embedded store” without a concrete adapter boundary, use the explicit `tet_store_memory`, `tet_store_sqlite`, and optional `tet_store_postgres` names.

If someone wants Ecto schemas in core, reject it. Ecto belongs in concrete store adapters, not in pure core contracts.

If Phoenix wants direct store access for convenience, reject it. UI state changes go through `Tet.*` and runtime/store contracts.

## Consequences

- Migration and backup docs must target `.tet/tet.sqlite` for standalone mode.
- Store contract tests should run against memory and SQLite, with Postgres added when enabled.
- Artifacts need content addressing, redaction metadata, and retention policy by kind/privacy class.
- Event Log and workflow journal interactions need clear docs so projection events are not confused with source-of-truth workflow steps.

## Review checklist

- [ ] Internal namespace is `Tet`, not `Agent`.
- [ ] Workspace metadata defaults to `.tet/` and `.tet/tet.sqlite`.
- [ ] Store adapters are named explicitly as memory, SQLite, and optional Postgres.
- [ ] Product docs use the reserved state terms consistently.
- [ ] UI adapters do not write storage directly.
