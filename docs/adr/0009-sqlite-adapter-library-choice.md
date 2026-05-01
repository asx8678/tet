# ADR-0009: SQLite Adapter Library Choice

**Status**: Accepted
**Accepted on 2026-04-30** by user via `planning-agent-24d9f8`
**Date**: 2026-04-30
**Deciders**: User approval pending; `planning-agent-24d9f8` roadmap owner; `adr-writer-2ea39e` author

## Context

Phase 2 of the JSONL→SQLite migration must choose the library used by `apps/tet_store_sqlite/` to talk to SQLite before dependency edits land. The current adapter is still a dependency-free JSONL placeholder: `apps/tet_store_sqlite/mix.exs` depends only on `:tet_core`, and the migration design says no schema, migration, code, or dependency edits were made in Phase 1. This ADR is therefore a phase gate, not a post-hoc implementation note.

The controlling v0.3 dependency rule is explicit, not ambiguous: `tet_store_sqlite -> tet_core, ecto_sql, sqlite adapter`, while `tet_store_postgres -> tet_core, ecto_sql, postgrex`. The same v0.3 implementation example names `{:ecto_sql, "~> 3.11"}` and `{:ecto_sqlite3, "~> 0.15"}` for `tet_store_sqlite`. Choosing raw `exqlite` as the direct programming model would therefore be a spec departure requiring explicit amendment, even though `exqlite` may appear transitively under `ecto_sqlite3`.

The storage contract constrains the choice. v0.3 requires the default standalone store to be `repo-root/.tet/tet.sqlite`, with all persistence behind the `Tet.Store` behaviour and database schemas mapping to/from `tet_core` domain structs rather than becoming the domain model. The same contract expects workspace, session, task, message, tool-run, approval, artifact, event, and transaction behaviour to pass shared storage contract tests.

The release constraints are also material. `tet_standalone` includes `tet_core`, `tet_runtime`, `tet_cli`, `tet_store_sqlite`, and a selected provider adapter, while forbidding Phoenix, LiveView, Phoenix.PubSub, Plug, Cowboy, Bandit, `tet_web_phoenix`, and web assets. Ecto is not forbidden by v0.3 or by the current root release/closure scripts, but it increases closure mass and therefore must be verified after the dependency change.

The SQLite migration design records a real tradeoff. The SQLite specialist prefers direct `exqlite` for explicit connection ownership, smaller closure, direct PRAGMA/WAL/checkpoint control, and a hand-rolled runtime migration path. The same design also records the architect's reading that strict v0.3 compliance means `ecto_sqlite3` unless an ADR/spec amendment approves raw `exqlite`, and warns that an Ecto-style write pool must not be used for SQLite.

## Decision

Use **Option A: `ecto_sqlite3` with `ecto_sql`** as the Phase-2 SQLite adapter library for `apps/tet_store_sqlite/`. `tet_store_sqlite` will use the Ecto SQL adapter shape required by v0.3, while enforcing SQLite-specific operational constraints: exactly one writer path, no generic pooled writes, explicit per-connection PRAGMA verification, no reliance on `mix ecto.migrate` at runtime, and a release-closure check after dependency changes.

## Decision Drivers

| Driver | Option A — `ecto_sqlite3` / `ecto_sql` | Option B — direct `exqlite` |
|---|---|---|
| **v0.3 §02 alignment** | **Strong.** Directly matches `docs/02_dependency_rules_and_guards.md` §Allowed dependencies and the v0.3 implementation example for `tet_store_sqlite`. This is decisive for a phase gate because no spec amendment is needed. | **Weak.** Conflicts with the written dependency rule. It is viable only if this ADR is treated as an explicit spec amendment and accepted as such. |
| **Closure size** | **Weaker.** Adds `ecto`, `ecto_sql`, `db_connection`, `decimal`, and the SQLite adapter stack. v0.3/current scripts do not forbid these, but closure mass grows and must be measured after the dep edit. | **Stronger.** Smaller direct dependency surface: primarily the SQLite NIF wrapper. This best serves the standalone binary-size/minimal-closure preference. |
| **Single-writer fit** | **Acceptable with discipline.** Must use a single writer GenServer / writer repo connection / pool size 1, plus separate read paths. A default Ecto pool used for writes is explicitly rejected. | **Stronger.** Raw connection ownership naturally matches the single-writer design and avoids an extra pooling abstraction between the adapter and SQLite. |
| **Migration tooling** | **Stronger, with release caveat.** Can use Ecto migration conventions and `schema_migrations`; runtime releases still cannot rely on Mix tasks, so any migrator must run in-app or through carefully controlled `Ecto.Migrator` usage. | **Weaker.** Requires a hand-rolled migration runner and schema-version table. This is manageable but more adapter-owned code. |
| **Consistency with optional Postgres adapter** | **Stronger.** Matches the v0.3 target that both SQLite and optional Postgres adapters use `ecto_sql`. Current repository inspection found no `apps/tet_store_postgres/`, so this is future-plan consistency, not current-code parity. | **Weaker.** SQLite and future Postgres adapters would use different I/O models: raw NIF for SQLite, Ecto SQL for Postgres. The `Tet.Store` contract hides this from callers, but adapter implementation/test mechanics diverge. |
| **Complexity for callers** | **Neutral-to-strong.** Callers still use `Tet.Store`; Ecto stays inside the adapter. Adapter internals get familiar query/migration idioms. | **Neutral-to-weak.** Callers still use `Tet.Store`; adapter internals must expose a thin SQL wrapper or raw SQL functions for every operation. |
| **PRAGMA control** | **Acceptable but indirect.** Must issue and verify PRAGMAs through `Ecto.Adapters.SQL.query!` or equivalent for every writer, reader, checkpoint, and backup-verifier connection. | **Stronger.** Direct API calls make WAL, foreign-key, busy-timeout, and checkpoint control more explicit. |
| **Schema-version tracking** | **Stronger.** `schema_migrations` and migration ordering are already modeled by Ecto conventions, though runtime execution remains adapter-owned. | **Weaker.** Requires custom `schema_migrations` DDL and transaction semantics. The design already sketches this, but it is extra code and tests. |

## Recommendation

Recommend **Option A (`ecto_sqlite3`)** for Phase 2.

The strongest reasons are:

1. **Spec alignment is decisive for this gate.** v0.3 §02 and the v0.3 implementation example explicitly select the `ecto_sql` + SQLite-adapter shape. Option B would be a spec amendment, not a normal implementation choice.
2. **It preserves future adapter consistency.** Optional Postgres is not present in the repository today, but the v0.3 architecture expects `tet_store_postgres` to use `ecto_sql` + `postgrex`; keeping SQLite on the same adapter family reduces future contract-test and migration drift.
3. **Migration/versioning support reduces Phase-2 risk.** The migration from JSONL to first-class tables needs schema-version tracking and startup migrations without Mix. Ecto conventions reduce bespoke migration machinery, provided runtime migration execution is implemented deliberately.

This recommendation accepts two costs: a larger standalone closure and stricter implementation discipline to prevent pooled writes. Those costs are visible, testable, and compatible with v0.3. A raw `exqlite` implementation may be revisited by a later ADR if measured closure size, runtime control, or backup requirements become blocking.

## Consequences

**Positive / what becomes easier**:

- Phase 2 can proceed without a v0.3 spec amendment because the dependency choice matches `docs/02_dependency_rules_and_guards.md` §Allowed dependencies.
- SQLite and future optional Postgres adapters share the Ecto SQL family, reducing future divergence in migration conventions, transaction handling, and storage contract tests.
- Schema-version tracking can use Ecto-style `schema_migrations` rather than a fully custom version ledger.
- Adapter code can use `Ecto.Adapters.SQL` for query execution while still mapping rows to `tet_core` structs and keeping Ecto out of `tet_core`.

**Negative / what becomes harder**:

- The standalone release closure becomes larger than a direct `exqlite` design; Phase 2 must run the release closure script and inspect the built release after adding dependencies.
- The SQLite writer design needs active guardrails. A normal Ecto pool must not become a multi-writer path; the implementation must centralize writes through one writer process/connection and test concurrent write pressure.
- PRAGMA/WAL/checkpoint control is more indirect than raw `exqlite`; every connection must be initialized and verified explicitly.
- Runtime migrations cannot be delegated to `mix ecto.migrate`; the release needs an in-application migration barrier or carefully controlled `Ecto.Migrator` call path.

**Neutral / reversibility**:

- Reversibility is **moderate** if the `Tet.Store` behaviour remains the only caller-facing seam and SQL/mapping code is kept adapter-local. Contract tests should make a future switch to direct `exqlite` possible without changing runtime, CLI, or UI callers.
- Reversibility becomes **hard** if Ecto schemas, changesets, repos, or query idioms leak into `tet_core`, `tet_runtime`, `tet_cli`, or optional UI code. This ADR explicitly forbids that leak.
- A later switch to direct `exqlite` would require a new ADR/spec amendment, dependency cleanup, migration-runner replacement, release-closure remeasurement, and full storage contract test parity.

## Alternatives Considered

1. **Option A: `ecto_sqlite3` with `ecto_sql`** — selected.

   Pros:
   - Complies with v0.3 `docs/02` §Allowed dependencies and the implementation example for `tet_store_sqlite`.
   - Aligns with the future optional `tet_store_postgres` shape (`ecto_sql` + `postgrex`).
   - Provides known migration/versioning conventions and transaction/query APIs.
   - Does not violate the standalone release's explicit web-framework bans; Ecto is not Phoenix/Plug/Cowboy/LiveView.

   Cons:
   - Larger closure than direct `exqlite`.
   - Adds an abstraction layer that can obscure SQLite connection ownership if not constrained.
   - Requires explicit implementation rules to avoid a write pool and to verify PRAGMAs on every connection.
   - Runtime migration still needs release-safe execution; Mix tasks are not available in the release.

2. **Option B: direct `exqlite`** — rejected for Phase 2 unless the user explicitly accepts a spec amendment.

   Pros:
   - Best technical fit for a single-writer SQLite architecture with explicit connection ownership.
   - Smaller standalone closure.
   - Direct PRAGMA, WAL, checkpoint, and backup control.
   - Straightforward custom SQL migration runner with no Ecto runtime conventions.

   Cons:
   - Contradicts the current v0.3 dependency rule for `tet_store_sqlite` and the v0.3 implementation example.
   - Weakens consistency with the future optional Postgres adapter.
   - Requires hand-rolled migration/version tracking and additional adapter-owned tests.
   - Makes Phase 2 depend on an architectural/spec-amendment decision rather than a normal implementation choice.

## References

- v0.3 plan: `check this plans/plan claude/plan_v0.3/docs/02_dependency_rules_and_guards.md` §Allowed dependencies, §The five gates, §Gate B5 — release closure check, §Removability test.
- v0.3 plan: `check this plans/plan claude/plan_v0.3/docs/04_data_storage_events.md` §Storage goal, §Domain entities, §Store behaviour.
- v0.3 plan: `check this plans/plan claude/plan_v0.3/docs/08_release_profiles_testing_acceptance.md` §Release A — `tet_standalone`, §Testing layers, §Acceptance criteria.
- v0.3 plan: `check this plans/plan claude/plan_v0.3/docs/07_build_order_migration.md` §Phase 2 — Runtime foundation and public facade, §Phase 3 — Storage adapters and workspace init.
- v0.3 plan: `check this plans/plan claude/plan_v0.3/implementation/mix_and_release_examples.md` §`tet_store_sqlite`, §Runtime config sketch.
- SQLite migration design: `apps/tet_store_sqlite/DESIGN_SQLITE_MIGRATION.md` §1 Executive Summary, §4 PRAGMA Configuration, §5 Adapter Library Choice, §6 Single-Writer Architecture, §15 Open Questions / Decisions Needed.
- Current SQLite app deps: `apps/tet_store_sqlite/mix.exs` §`deps/0`.
- Current release profile and guards: `mix.exs` §`@standalone_applications`, §`assert_standalone_release!/1`, §`releases/0`; `tools/check_release_closure.sh` §forbidden library scan and required boundary apps.
- SQLite WAL documentation: <https://www.sqlite.org/wal.html>.
- SQLite PRAGMA documentation: <https://www.sqlite.org/pragma.html>.
