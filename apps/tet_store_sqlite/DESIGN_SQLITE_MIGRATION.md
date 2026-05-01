# JSONL → SQLite Migration Design (Phase 1 Discovery & Design)

Owner: `sqlite-embedded-specialist-9503cb`  
Tasking agent: `planning-agent-24d9f8`  
Scope: **design document only**. No schema files, no migrations, no Elixir code edits, no dependency edits.

> SQLite is not Postgres with a cuter file extension, and it is not a JSONL file with ambitions. This design keeps the `Tet.Store` behaviour as the seam, moves durable state to `.tet/tet.sqlite`, and refuses the usual footguns: multiple writers, silent rollback-journal fallback, raw `cp` backups, NFS, and web-framework leakage into the standalone release.

---

## 1. Executive Summary

The current `Tet.Store.SQLite` module is a dependency-free JSON Lines placeholder that writes chat messages, autosaves, runtime events, and Prompt Lab history into separate `.jsonl` files under `.tet/`. The v0.3 storage plan requires the default standalone store to be a real workspace-scoped SQLite database at `.tet/tet.sqlite`, with first-class tables for workspaces, sessions, tasks, messages, tool runs, approvals, artifacts, events, and the durable workflow journal from §12. The recommended migration shape is a single SQLite writer process, WAL mode, small read fan-out, startup migrations without Mix, a one-time idempotent JSONL importer, and strict release-closure checks. The biggest risks are behaviour-contract drift between current code and v0.3 docs, the adapter-library conflict (`exqlite` technical fit vs. v0.3 dependency text preferring `ecto_sqlite3`), and getting crash recovery / JSONL import idempotency wrong. Expected implementation size after approval is medium-large: roughly six focused implementation phases, with cross-agent decisions required before dependency and behaviour changes land.

---

## 2. Current State Analysis

### Required files read

Read before drafting:

- `apps/tet_store_sqlite/lib/tet/store/sqlite.ex`
- `apps/tet_store_sqlite/test/prompt_history_test.exs`
- `apps/tet_core/lib/tet/store.ex`
- `apps/tet_core/lib/tet/event.ex`
- `apps/tet_core/lib/tet/message.ex`
- `apps/tet_core/lib/tet/session.ex`
- `apps/tet_core/lib/tet/autosave.ex`
- `apps/tet_core/lib/tet/prompt_lab/history_entry.ex`
- `check this plans/plan claude/plan_v0.3/docs/04_data_storage_events.md`
- `check this plans/plan claude/plan_v0.3/upgrades/12_durable_execution.md`
- `check this plans/plan claude/plan_v0.3/diagrams/storage_event_flow.mmd`
- `check this plans/plan claude/plan_v0.3/diagrams/crash_recovery.mmd`
- `check this plans/plan claude/plan_v0.3/diagrams/supervision_tree_v03.mmd`
- `check this plans/plan claude/plan_v0.3/docs/02_dependency_rules_and_guards.md`
- `check this plans/plan claude/plan_v0.3/upgrades/14_secrets_and_redaction.md`
- `check this plans/plan claude/plan_v0.3/upgrades/17_phasing_and_scope.md`
- `check this plans/plan claude/plan_v0.3/upgrades/18_test_strategy.md`
- `check this plans/plan claude/plan_v0.3/upgrades/19_migration_path.md`
- `apps/tet_store_sqlite/mix.exs`
- root `mix.exs`
- `config/config.exs`
- `tools/check_release_closure.sh`
- production callers under `apps/tet_runtime/lib`, `apps/tet_cli/lib`, and `apps/tet_web_phoenix/lib`

### What the JSONL placeholder covers vs. v0.3 entity list

Current placeholder files and defaults from `Tet.Store.SQLite`:

| Current data | Current file | Current mechanism | v0.3 target |
|---|---:|---|---|
| Chat messages | `.tet/messages.jsonl` | Append JSON line from `Tet.Message.to_map/1`; list scans whole file and filters by `session_id` | `messages` table plus first-class `sessions` table (§04 / `Tet.Message`, `Tet.Session`) |
| Sessions | No table/file | Derived from grouped messages via `Tet.Session.from_messages/2` | `sessions` table, workspace-owned, status/mode/provider/model metadata (§04 / `Tet.Session`) |
| Runtime events | `.tet/events.jsonl` | Append JSON line from `Tet.Event.to_map/1`; sequence assigned by scanning all prior events | `events` table, durable per-session monotonic timeline; unique `(session_id, seq)` (§04 / `Tet.Event`) |
| Autosaves | `.tet/autosaves.jsonl` | Append JSON line from `Tet.Autosave.to_map/1`; latest selected by `saved_at` | Not listed as one of the 8 v0.3 domain entities, but present in current `Tet.Store`; needs compatibility table or behaviour change before cutover |
| Prompt Lab history | `.tet/prompt_history.jsonl` | Append JSON line from `Tet.PromptLab.HistoryEntry.to_map/1` | Prompt Lab is not a v0.3 storage entity in §04, but current `Tet.Store` exposes callbacks; needs compatibility table |
| Workspaces | None | Runtime config has a store path only; no persisted workspace row | `workspaces` table (§04 / `Tet.Workspace`) |
| Tasks | None | Not persisted by current placeholder | `tasks` table (§04 / `Tet.Task`) |
| Tool runs | None | Not persisted by current placeholder | `tool_runs` table (§04 / `Tet.ToolRun`) |
| Approvals | None | Not persisted by current placeholder | `approvals` table with one pending approval per session (§04 / `Tet.Approval`) |
| Artifacts | None | No content-addressed blob store yet | `artifacts` table plus `.tet/artifacts/<kind>/<sha256>` (§04 / `Tet.Artifact`) |
| Workflow journal | None | Current runtime is not journal-driven | `workflows`, `workflow_steps` tables (§12 / journal storage and idempotency) |

**Gap summary:** JSONL currently covers only the scaffold-era chat/autosave/event/prompt-history surface. It does not persist workspaces, tasks, tool runs, approvals, artifacts, workflow journal rows, migration versions, or database integrity metadata. Sessions are derived summaries, not durable rows. Event sequence assignment scans a file and is global-ish in practice, not an atomic per-session transaction. That is exactly the sort of tiny gremlin that becomes a recovery bug under load.

Citation: `docs/04_data_storage_events.md` says the default file is `repo-root/.tet/tet.sqlite`, all persistence goes through `Tet.Store`, and SQLite/Postgres schemas map to/from core structs rather than becoming the domain model. `upgrades/12_durable_execution.md` makes the workflow journal the source of truth before side effects run.

### Current `Tet.Store` callbacks in code vs. placeholder implementation

`apps/tet_core/lib/tet/store.ex` currently defines this behaviour. The placeholder implements every current callback.

| Callback in current `tet_core` | Placeholder implemented? | Current JSONL behaviour | SQLite migration design note |
|---|---:|---|---|
| `boundary/0` | Yes | Reports `status: :local_jsonl`, paths, `format: :jsonl` | Must report SQLite DB path, WAL status, schema version, checkpoint config |
| `health/1` | Yes | Creates/checks JSONL directory; probes read/write | Must open DB, apply/verify PRAGMAs, run lightweight health, report schema/migrations and network-mount refusal |
| `save_message/2` | Yes | Append to messages JSONL | Writer transaction; ensure workspace/session row; allocate message `seq`; insert `messages`; optionally emit/update session summary |
| `list_messages/2` | Yes | Scan file, filter by `session_id` | Reader query ordered by `(session_id, seq)` or `created_at` |
| `list_sessions/1` | Yes | Derive sessions by grouping messages | Query `sessions` table, with compatibility for legacy imported sessions |
| `fetch_session/2` | Yes | Derive one session from messages | Query `sessions`; return current `Tet.Session` struct shape, not SQLite row map |
| `save_autosave/2` | Yes | Append to autosaves JSONL | Compatibility `autosaves` table unless current behaviour is replaced by v0.3 store callbacks |
| `load_autosave/2` | Yes | Scan autosaves; newest by `saved_at` | Query `autosaves` by `session_id`, newest first |
| `list_autosaves/1` | Yes | Scan autosaves; sort newest first | Query `autosaves` ordered by `saved_at DESC` |
| `save_event/2` | Yes | Scan JSONL to assign `sequence`; append | Writer transaction; atomic `MAX(seq)+1 WHERE session_id=?`; insert `events`; retry on unique conflict |
| `list_events/2` | Yes | Scan events; optional `session_id` filter | Reader query all or by session, ordered by `(session_id, seq)` / inserted time |
| `save_prompt_history/2` | Yes | Append to prompt history JSONL | Compatibility `prompt_history_entries` table |
| `list_prompt_history/1` | Yes | Scan prompt history; sort newest first | Query `prompt_history_entries` ordered by `created_at DESC` |
| `fetch_prompt_history/2` | Yes | Scan and find by id | Query `prompt_history_entries` by primary key |

### v0.3 store callbacks not yet present in current `tet_core`

`docs/04_data_storage_events.md` lists a future richer `Tet.Store` contract: `transaction/1`, workspace/session/task/tool/approval/artifact/event callbacks. `upgrades/12_durable_execution.md` adds workflow journal callbacks: `start_step/1`, `commit_step/2`, `fail_step/2`, `cancel_step/1`, `list_pending_workflows/0`, `list_steps/1`, `claim_workflow/3`, plus schema-version expectations in `upgrades/19_migration_path.md`.

Those callbacks are **not currently in `apps/tet_core/lib/tet/store.ex`**. This is a boundary issue owned by `elixir-programmer`, not the SQLite adapter. Phase 2 must decide whether to:

1. implement SQLite behind the current scaffold behaviour only, then expand behaviour later; or
2. first update `tet_core` to the v0.3 store behaviour and shared contract tests, then implement SQLite against the final contract.

SQLite recommendation: do **not** leak SQLite-specific APIs upward to compensate. The behaviour is the seam. If the seam is too small, fix it in `tet_core` with the owner.

### Store caller inventory across `apps/`

Read-only grep results show the production blast radius is concentrated in runtime and facade layers. Direct store calls are not scattered through CLI or Phoenix, which is good. Keep it that way.

| Caller | File | Store surface used | Notes |
|---|---|---|---|
| Store adapter resolver | `apps/tet_runtime/lib/tet/runtime/store_config.ex` | Checks callback availability; normalizes `:path`, `:autosave_path`, `:events_path`, `:prompt_history_path` | Must be updated in Phase 2 for DB path semantics and legacy JSONL import paths |
| Chat runtime | `apps/tet_runtime/lib/tet/runtime/chat.ex` | `save_message`, `list_messages`, `save_event` | Current event persistence failure is swallowed in `persist_event/3`; durable timeline priority says Phase 2 should revisit this with runtime owner |
| Autosave runtime | `apps/tet_runtime/lib/tet/runtime/autosave.ex` | `list_messages`, `save_autosave`, `load_autosave`, `list_autosaves` | Requires compatibility tables or behaviour replacement |
| Sessions runtime | `apps/tet_runtime/lib/tet/runtime/sessions.ex` | `list_sessions`, `fetch_session`, `list_messages` | Should not derive sessions by scanning messages after cutover |
| Compaction runtime | `apps/tet_runtime/lib/tet/runtime/compaction.ex` | `list_messages` | Read-only; should use reader pool |
| Prompt Lab runtime | `apps/tet_runtime/lib/tet/runtime/prompt_lab.ex` | `save_prompt_history`, `list_prompt_history`, `fetch_prompt_history` | Existing test specifically checks Prompt Lab history does not touch other stores |
| Timeline runtime | `apps/tet_runtime/lib/tet/runtime/timeline.ex` | `list_events` | Reader path; optional filter by session |
| Doctor runtime | `apps/tet_runtime/lib/tet/runtime/doctor.ex` | `StoreConfig.health/1`, adapter/path reporting | Should include schema version, WAL status, mount check, integrity status |
| Public facade | `apps/tet_runtime/lib/tet.ex` | Calls runtime modules only | CLI and Phoenix must continue to use `Tet.*` facade |
| CLI | `apps/tet_cli/lib/tet/cli.ex` | `Tet.list_sessions/0`, `Tet.show_session/1`, `Tet.list_events/1`, `Tet.ask/2`, `Tet.doctor/0` | No direct store calls; keep facade-only |
| Optional Phoenix | `apps/tet_web_phoenix/lib/tet_web_phoenix/event_log.ex` | `Tet.list_events/1/2` | Optional UI uses facade only; must not gain direct SQLite deps |
| SQLite test | `apps/tet_store_sqlite/test/prompt_history_test.exs` | Direct `Tet.Store.SQLite.*` prompt-history callbacks | Needs rewrite to SQLite temp DB plus JSONL import/cutover tests |

Additional tests reference the public facade and store paths, including `apps/tet_runtime/test/tet/chat_test.exs`, `autosave_restore_test.exs`, `prompt_lab_runtime_test.exs`, and `apps/tet_cli/test/tet_cli_test.exs`. Current tests assume `.jsonl` paths; Phase 2 must update them to per-test `.tet/tet.sqlite` paths and legacy-import fixtures.

---

## 3. Schema Design

### Design rules and citations

- `docs/04_data_storage_events.md` defines the eight v0.3 domain entities and says default local storage is `repo-root/.tet/tet.sqlite`.
- `upgrades/12_durable_execution.md` defines the workflow journal and idempotency invariants: every side effect is checkpointed before it runs, and `(workflow_id, idempotency_key)` enforces exactly-once logical step commit.
- Current `tet_core` structs are smaller than v0.3 docs. The schema below targets v0.3 while preserving compatibility tables for the current callbacks.
- SQLite foreign keys are per-connection and disabled by default unless `PRAGMA foreign_keys = ON` is set; every connection must enable it (sqlite.org/pragma.html#pragma_foreign_keys). SQLite also does **not** auto-index child FK columns. Yes, really. We add indexes.

### Column-type decisions

| Concern | Decision | Rationale |
|---|---|---|
| Primary IDs | `TEXT PRIMARY KEY`, non-empty; v0.3 target UUIDv4 text | `docs/04` says UUIDv4 and short ids. Current code emits `ses_...`, `msg_...`, `req_...`, and current structs accept any non-empty binary. A strict UUID `CHECK(length(id)=36)` would break the current runtime. Recommendation: store as `TEXT` now, coordinate with `elixir-programmer` to move `Tet.Runtime.Ids` / core IDs to UUIDv4 before adding stricter checks. Do not use `BLOB(16)` without benchmarks. |
| Short ids | `TEXT` columns where user-facing lookup needs them | Short ids are CLI display/lookup affordances. Prefixes (`s_`, `appr_`, `art_`, `t_`) avoid cross-kind ambiguity. Enforce uniqueness per workspace where workspace_id is available; otherwise use adapter-level resolver or a future `workspace_short_ids` table. |
| Timestamps | `INTEGER` Unix milliseconds in DB; map to/from ISO8601/current core strings at adapter boundary | Efficient ordering/range queries, compact storage, no timezone ambiguity. Current `Tet.Message.timestamp` / `Tet.Autosave.saved_at` are strings; adapter maps. |
| Maps / payloads | `BLOB` containing canonical JSON bytes | Avoids requiring SQLite JSON1 for correctness. Core validates shape; adapter serializes deterministically where idempotency requires it. |
| Message content | `content_kind TEXT`, `content BLOB` | Today content is text. BLOB leaves room for encoded rich content without schema churn. |
| Large artifacts | Inline below threshold; file spill at/above threshold | Default threshold `16_384` bytes per storage invariant. Spill path `.tet/artifacts/<kind>/<sha256>`, written tmp-then-rename. |
| Event sequence | `seq INTEGER NOT NULL` per session, unique `(session_id, seq)` | §04 says event seq is monotonic per session. Allocation occurs in same writer transaction as insert. Do not use `last_insert_rowid()`. |

### Required DDL — core v0.3 tables + workflow journal

> Policy: migration `up` is forward-only for production. A sketched `down` can exist for dev, but runtime releases recover by restoring from backup, not by destructive rollback. SQLite DDL is transactional; each migration records `schema_migrations` in the same transaction as the DDL.

```sql
-- Migration 0001_initial_v03_sqlite_schema (design draft)
-- Run only after PRAGMA auto_vacuum = INCREMENTAL has been set on a new DB
-- and before any user tables exist.

CREATE TABLE IF NOT EXISTS schema_migrations (
  version     INTEGER PRIMARY KEY,
  name        TEXT NOT NULL,
  applied_at  INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS workspaces (
  id            TEXT PRIMARY KEY CHECK (length(id) > 0),
  name          TEXT NOT NULL,
  root_path     TEXT NOT NULL UNIQUE,
  tet_dir_path  TEXT NOT NULL,
  trust_state   TEXT NOT NULL CHECK (trust_state IN ('untrusted', 'trusted')),
  metadata      BLOB NOT NULL DEFAULT X'7B7D',
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
  id              TEXT PRIMARY KEY CHECK (length(id) > 0),
  workspace_id    TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  short_id        TEXT NOT NULL,
  title           TEXT,
  mode            TEXT NOT NULL CHECK (mode IN ('chat', 'explore', 'execute')),
  status          TEXT NOT NULL CHECK (status IN ('idle', 'running', 'waiting_approval', 'complete', 'error')),
  provider        TEXT,
  model           TEXT,
  active_task_id  TEXT REFERENCES tasks(id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED,
  metadata        BLOB NOT NULL DEFAULT X'7B7D',
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL,
  UNIQUE (workspace_id, short_id)
);

CREATE INDEX IF NOT EXISTS sessions_workspace_created_idx
  ON sessions(workspace_id, created_at DESC);

CREATE INDEX IF NOT EXISTS sessions_active_task_idx
  ON sessions(active_task_id)
  WHERE active_task_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS tasks (
  id          TEXT PRIMARY KEY CHECK (length(id) > 0),
  session_id  TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  short_id    TEXT NOT NULL,
  title       TEXT,
  kind        TEXT NOT NULL DEFAULT 'agent_task',
  status      TEXT NOT NULL CHECK (status IN ('active', 'complete', 'cancelled')),
  payload     BLOB,
  metadata    BLOB NOT NULL DEFAULT X'7B7D',
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL,
  UNIQUE (session_id, short_id)
);

CREATE INDEX IF NOT EXISTS tasks_session_created_idx
  ON tasks(session_id, created_at);

CREATE INDEX IF NOT EXISTS tasks_session_status_idx
  ON tasks(session_id, status);

CREATE TABLE IF NOT EXISTS messages (
  id            TEXT PRIMARY KEY CHECK (length(id) > 0),
  session_id    TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  role          TEXT NOT NULL CHECK (role IN ('system', 'user', 'assistant', 'tool')),
  content_kind  TEXT NOT NULL DEFAULT 'text',
  content       BLOB NOT NULL,
  metadata      BLOB NOT NULL DEFAULT X'7B7D',
  seq           INTEGER NOT NULL CHECK (seq > 0),
  created_at    INTEGER NOT NULL,
  UNIQUE (session_id, seq)
);

CREATE INDEX IF NOT EXISTS messages_session_created_idx
  ON messages(session_id, created_at);

CREATE TABLE IF NOT EXISTS tool_runs (
  id             TEXT PRIMARY KEY CHECK (length(id) > 0),
  session_id     TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  task_id        TEXT REFERENCES tasks(id) ON DELETE SET NULL,
  tool_name      TEXT NOT NULL,
  read_or_write  TEXT NOT NULL CHECK (read_or_write IN ('read', 'write')),
  args           BLOB NOT NULL DEFAULT X'7B7D',
  result         BLOB,
  status         TEXT NOT NULL CHECK (status IN ('proposed', 'blocked', 'waiting_approval', 'running', 'success', 'error')),
  block_reason   TEXT,
  changed_files  BLOB NOT NULL DEFAULT X'5B5D',
  metadata       BLOB NOT NULL DEFAULT X'7B7D',
  started_at     INTEGER,
  finished_at    INTEGER
);

CREATE INDEX IF NOT EXISTS tool_runs_session_started_idx
  ON tool_runs(session_id, started_at);

CREATE INDEX IF NOT EXISTS tool_runs_task_idx
  ON tool_runs(task_id)
  WHERE task_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS tool_runs_session_status_idx
  ON tool_runs(session_id, status);

CREATE TABLE IF NOT EXISTS approvals (
  id                TEXT PRIMARY KEY CHECK (length(id) > 0),
  session_id        TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  task_id           TEXT REFERENCES tasks(id) ON DELETE SET NULL,
  tool_run_id       TEXT NOT NULL REFERENCES tool_runs(id) ON DELETE CASCADE,
  short_id          TEXT NOT NULL,
  status            TEXT NOT NULL CHECK (status IN ('pending', 'approved', 'rejected', 'expired')),
  reason            TEXT,
  diff_artifact_id  TEXT REFERENCES artifacts(id) ON DELETE SET NULL,
  metadata          BLOB NOT NULL DEFAULT X'7B7D',
  created_at        INTEGER NOT NULL,
  updated_at        INTEGER NOT NULL,
  resolved_at       INTEGER,
  UNIQUE (session_id, short_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS approvals_one_pending_per_session
  ON approvals(session_id)
  WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS approvals_session_created_idx
  ON approvals(session_id, created_at DESC);

CREATE INDEX IF NOT EXISTS approvals_task_idx
  ON approvals(task_id)
  WHERE task_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS approvals_tool_run_idx
  ON approvals(tool_run_id);

CREATE INDEX IF NOT EXISTS approvals_diff_artifact_idx
  ON approvals(diff_artifact_id)
  WHERE diff_artifact_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS artifacts (
  id           TEXT PRIMARY KEY CHECK (length(id) > 0),
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  session_id   TEXT REFERENCES sessions(id) ON DELETE SET NULL,
  short_id     TEXT NOT NULL,
  kind         TEXT NOT NULL CHECK (kind IN ('diff', 'stdout', 'stderr', 'file_snapshot', 'prompt_debug', 'provider_payload')),
  sha256       TEXT NOT NULL CHECK (length(sha256) = 64 AND sha256 NOT GLOB '*[^0-9a-f]*'),
  size_bytes   INTEGER NOT NULL CHECK (size_bytes >= 0),
  inline_blob  BLOB,
  path         TEXT,
  metadata     BLOB NOT NULL DEFAULT X'7B7D',
  created_at   INTEGER NOT NULL,
  CHECK ((inline_blob IS NULL) <> (path IS NULL)),
  UNIQUE (workspace_id, sha256),
  UNIQUE (workspace_id, short_id)
);

CREATE INDEX IF NOT EXISTS artifacts_workspace_kind_created_idx
  ON artifacts(workspace_id, kind, created_at DESC);

CREATE INDEX IF NOT EXISTS artifacts_session_created_idx
  ON artifacts(session_id, created_at DESC)
  WHERE session_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS events (
  id          TEXT PRIMARY KEY CHECK (length(id) > 0),
  session_id  TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  seq         INTEGER NOT NULL CHECK (seq > 0),
  type        TEXT NOT NULL,
  payload     BLOB NOT NULL DEFAULT X'7B7D',
  metadata    BLOB NOT NULL DEFAULT X'7B7D',
  inserted_at INTEGER NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS events_session_seq
  ON events(session_id, seq);

CREATE INDEX IF NOT EXISTS events_session_inserted_idx
  ON events(session_id, inserted_at);

CREATE TABLE IF NOT EXISTS workflows (
  id               TEXT PRIMARY KEY CHECK (length(id) > 0),
  session_id       TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  task_id          TEXT REFERENCES tasks(id) ON DELETE SET NULL,
  status           TEXT NOT NULL CHECK (status IN ('running', 'paused_for_approval', 'completed', 'failed', 'cancelled')),
  claimed_by       TEXT,
  claim_expires_at INTEGER,
  metadata         BLOB NOT NULL DEFAULT X'7B7D',
  created_at       INTEGER NOT NULL,
  updated_at       INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS workflows_session_status_idx
  ON workflows(session_id, status, updated_at DESC);

CREATE INDEX IF NOT EXISTS workflows_task_idx
  ON workflows(task_id)
  WHERE task_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS workflows_pending_idx
  ON workflows(status, updated_at)
  WHERE status IN ('running', 'paused_for_approval');

CREATE UNIQUE INDEX IF NOT EXISTS workflows_one_paused_per_session
  ON workflows(session_id)
  WHERE status = 'paused_for_approval';

CREATE TABLE IF NOT EXISTS workflow_steps (
  id               TEXT PRIMARY KEY CHECK (length(id) > 0),
  workflow_id      TEXT NOT NULL REFERENCES workflows(id) ON DELETE CASCADE,
  step_name        TEXT NOT NULL CHECK (
                     length(step_name) > 0
                     AND step_name NOT GLOB '*[^a-z0-9_:]*'
                     AND substr(step_name, 1, 1) GLOB '[a-z_]'
                     AND substr(step_name, -1, 1) <> ':'
                     AND instr(step_name, '::') = 0
                     AND (
                       (instr(step_name, ':') = 0 AND step_name NOT GLOB '*[0-9]*')
                       OR
                       (instr(step_name, ':') > 0 AND substr(step_name, 1, instr(step_name, ':') - 1) NOT GLOB '*[0-9]*')
                     )
                   ),
  idempotency_key  TEXT NOT NULL CHECK (length(idempotency_key) = 64 AND idempotency_key NOT GLOB '*[^0-9a-f]*'),
  input            BLOB NOT NULL DEFAULT X'7B7D',
  output           BLOB,
  status           TEXT NOT NULL CHECK (status IN ('started', 'committed', 'failed', 'cancelled')),
  attempt          INTEGER NOT NULL DEFAULT 1 CHECK (attempt >= 1),
  metadata         BLOB NOT NULL DEFAULT X'7B7D',
  started_at       INTEGER NOT NULL,
  committed_at     INTEGER,
  failed_at        INTEGER,
  cancelled_at     INTEGER,
  UNIQUE (workflow_id, idempotency_key)
);

CREATE INDEX IF NOT EXISTS workflow_steps_workflow_started_idx
  ON workflow_steps(workflow_id, started_at);

CREATE INDEX IF NOT EXISTS workflow_steps_workflow_status_idx
  ON workflow_steps(workflow_id, status, started_at);

CREATE INDEX IF NOT EXISTS workflow_steps_step_name_idx
  ON workflow_steps(workflow_id, step_name, attempt);
```

#### Compatibility tables required by the current `Tet.Store` behaviour

These are not part of the eight v0.3 entities in `docs/04`, but they are required if Phase 2 must keep current callers working without first changing `Tet.Store`.

```sql
CREATE TABLE IF NOT EXISTS autosaves (
  checkpoint_id      TEXT PRIMARY KEY CHECK (length(checkpoint_id) > 0),
  session_id         TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  saved_at           INTEGER NOT NULL,
  messages           BLOB NOT NULL DEFAULT X'5B5D',
  attachments        BLOB NOT NULL DEFAULT X'5B5D',
  prompt_metadata    BLOB NOT NULL DEFAULT X'7B7D',
  prompt_debug       BLOB NOT NULL DEFAULT X'7B7D',
  prompt_debug_text  TEXT NOT NULL DEFAULT '',
  metadata           BLOB NOT NULL DEFAULT X'7B7D'
);

CREATE INDEX IF NOT EXISTS autosaves_session_saved_idx
  ON autosaves(session_id, saved_at DESC);

CREATE TABLE IF NOT EXISTS prompt_history_entries (
  id          TEXT PRIMARY KEY CHECK (length(id) > 0),
  version     TEXT NOT NULL,
  created_at  INTEGER NOT NULL,
  request     BLOB NOT NULL,
  result      BLOB NOT NULL,
  metadata    BLOB NOT NULL DEFAULT X'7B7D'
);

CREATE INDEX IF NOT EXISTS prompt_history_created_idx
  ON prompt_history_entries(created_at DESC);

CREATE TABLE IF NOT EXISTS legacy_jsonl_imports (
  source_kind   TEXT NOT NULL CHECK (source_kind IN ('messages', 'events', 'autosaves', 'prompt_history')),
  source_path   TEXT NOT NULL,
  source_size   INTEGER NOT NULL CHECK (source_size >= 0),
  source_mtime  INTEGER NOT NULL,
  sha256        TEXT NOT NULL CHECK (length(sha256) = 64 AND sha256 NOT GLOB '*[^0-9a-f]*'),
  row_count     INTEGER NOT NULL CHECK (row_count >= 0),
  imported_at   INTEGER NOT NULL,
  PRIMARY KEY (source_kind, source_path)
);
```

### Index rationale block

- `workspaces.root_path UNIQUE`: serves workspace lookup by canonical root and enforces one workspace row per directory (§04 / Workspace layout).
- `sessions(workspace_id, created_at DESC)`: serves `tet sessions` / session listing newest-first.
- `sessions(workspace_id, short_id) UNIQUE`: resolves CLI session short ids within one workspace (§04 / ID strategy).
- `sessions(active_task_id)`: child-FK lookup for `active_task_id` cleanup / validation; SQLite does not auto-index FKs.
- `tasks(session_id, created_at)`: serves task timeline/listing per session.
- `tasks(session_id, status)`: serves active task lookup and status filtering.
- `tasks(session_id, short_id) UNIQUE`: resolves task short ids in the session; if global per-workspace task short-id lookup is required, add a `workspace_short_ids` table or denormalized `workspace_id` in Phase 2.
- `messages(session_id, seq) UNIQUE`: serves transcript ordering and prevents duplicate per-session message sequence.
- `messages(session_id, created_at)`: serves time-range transcript reads and compaction history reads.
- `tool_runs(session_id, started_at)`: serves tool activity timelines.
- `tool_runs(task_id)`: FK index and task-scoped tool lookup.
- `tool_runs(session_id, status)`: serves pending/running tool queries.
- `approvals_one_pending_per_session`: enforces the §04 invariant at the DB layer; at most one pending approval per session. Application-level checks are race-condition bait.
- `approvals(session_id, created_at DESC)`: serves `tet approvals` / session approval listing.
- `approvals(task_id)`, `approvals(tool_run_id)`, `approvals(diff_artifact_id)`: FK indexes and lookup from task/tool/diff context.
- `artifacts(workspace_id, sha256) UNIQUE`: content-addressed dedup by workspace; same bytes are the same artifact identity.
- `artifacts(workspace_id, kind, created_at DESC)`: serves artifact listing by kind, newest-first.
- `artifacts(session_id, created_at DESC)`: serves session artifact timeline / optional UI panels.
- `events(session_id, seq) UNIQUE`: durable per-session monotonic event timeline (§04 / Event). Consumers tail by `seq > cursor`.
- `events(session_id, inserted_at)`: serves time-range event reads and dashboard projections.
- `workflows(session_id, status, updated_at DESC)`: serves runtime lookup of active/pending workflows per session.
- `workflows(task_id)`: FK index and workflow lookup for active task.
- `workflows(status, updated_at) WHERE status IN (...)`: serves `list_pending_workflows/0` at boot (§12 / Crash recovery).
- `workflows_one_paused_per_session`: enforces §12’s paused-for-approval exclusivity.
- `workflow_steps(workflow_id, idempotency_key) UNIQUE`: exactly-once logical step commit (§12 / Journal storage).
- `workflow_steps(workflow_id, started_at)`: serves ordered replay.
- `workflow_steps(workflow_id, status, started_at)`: serves recovery lookup for `status='started' AND committed_at IS NULL`.
- `workflow_steps(workflow_id, step_name, attempt)`: serves retry/attempt lookup by step grammar.
- `autosaves(session_id, saved_at DESC)`: serves current `load_autosave/2` latest-checkpoint query.
- `prompt_history_entries(created_at DESC)`: serves current `list_prompt_history/1` newest-first.
- `legacy_jsonl_imports(source_kind, source_path)`: makes the one-time importer idempotent and auditable.

### `up` / `down` policy

- `up`: create tables, constraints, and indexes in deterministic order; record `schema_migrations(version, name, applied_at)` in the same transaction.
- `down` sketch for dev only: drop indexes/tables in reverse dependency order, ending with `schema_migrations`. Do **not** expose production rollback as a runtime path. Production rollback is restore-from-backup. SQLite `VACUUM` / file rewrites during rollback are not a toy; use backups.

Open schema questions are listed in §15. The biggest are current prefixed IDs vs. v0.3 UUIDs and whether current autosave / Prompt Lab callbacks remain in `Tet.Store` or move to v0.3-specific contracts. Approval status spelling is no longer open: `:rejected` is locked per v0.3 §04 and user decision.

---

## 4. PRAGMA Configuration

### Required PRAGMA block

Every SQLite connection — writer, reader, checkpointer, backup verifier — must execute the per-connection block. `auto_vacuum = INCREMENTAL` is **not** in this per-connection block because it must be set once before any user tables exist.

```sql
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA foreign_keys = ON;
PRAGMA busy_timeout = 5000;
PRAGMA temp_store = MEMORY;
PRAGMA cache_size = -20000;
PRAGMA mmap_size = 268435456;
```

DB creation-only:

```sql
PRAGMA auto_vacuum = INCREMENTAL;
```

### WAL engagement verification

Design requirement: after `PRAGMA journal_mode = WAL`, query `PRAGMA journal_mode;` and refuse to start unless it returns exactly `wal`. SQLite can fail or downgrade depending on VFS/filesystem. Silent rollback-journal fallback breaks the concurrency design.

Raw-connection shape, if the user approves `exqlite`:

```elixir
@pragmas [
  "PRAGMA journal_mode = WAL;",
  "PRAGMA synchronous = NORMAL;",
  "PRAGMA foreign_keys = ON;",
  "PRAGMA busy_timeout = 5000;",
  "PRAGMA temp_store = MEMORY;",
  "PRAGMA cache_size = -20000;",
  "PRAGMA mmap_size = 268435456;"
]

Enum.each(@pragmas, fn sql ->
  case Exqlite.Sqlite3.execute(conn, sql) do
    :ok -> :ok
    {:error, reason} -> raise "SQLite PRAGMA failed: #{sql} -> #{inspect(reason)}"
  end
end)

case Exqlite.Sqlite3.fetch_all(conn, "PRAGMA journal_mode;") do
  {:ok, [["wal"]]} -> :ok
  {:ok, [[other]]} -> raise "SQLite refused WAL mode; got #{inspect(other)}"
  other -> raise "SQLite journal_mode verification failed: #{inspect(other)}"
end
```

Ecto SQL shape, if the user follows the current v0.3 dependency text and chooses `ecto_sqlite3`:

```elixir
Enum.each(@pragmas, fn sql ->
  Ecto.Adapters.SQL.query!(repo, sql, [])
end)

case Ecto.Adapters.SQL.query!(repo, "PRAGMA journal_mode;", []).rows do
  [["wal"]] -> :ok
  [[other]] -> raise "SQLite refused WAL mode; got #{inspect(other)}"
  other -> raise "SQLite journal_mode verification failed: #{inspect(other)}"
end
```

The exact code belongs in Phase 2, but the invariant does not: **no WAL, no adapter start**.

### PRAGMA rationale block

- `journal_mode = WAL`: required for concurrent readers with a single writer; see sqlite.org/wal.html. If WAL cannot engage, the adapter refuses startup.
- `synchronous = NORMAL`: per sqlite.org/pragma.html#pragma_synchronous, `NORMAL` is the WAL-recommended durability/performance point. `OFF` is corruption-on-power-loss dressed as a benchmark. `FULL` is usually unnecessary cost under WAL for our write rate.
- `foreign_keys = ON`: SQLite defaults this off per connection; forgetting it on the writer is a data-integrity bug.
- `busy_timeout = 5000`: protects against checkpoint / external-process contention. This is not a license for multiple writers; it is a seatbelt.
- `temp_store = MEMORY`: keeps temp sort/join work off disk for expected local workloads.
- `cache_size = -20000`: negative means KiB, not pages; ~20MB per connection. Yes, SQLite made this a footgun. Documented at sqlite.org/pragma.html#pragma_cache_size.
- `mmap_size = 268435456`: 256MB mmap ceiling for local disks. This improves read performance on large DBs without forcing the entire DB into memory; tune per platform in Phase 2.
- `auto_vacuum = INCREMENTAL`: must be set before tables exist; cannot be enabled retroactively without full `VACUUM` (sqlite.org/lang_vacuum.html). Runtime uses incremental vacuum; full `VACUUM` is a maintenance command, not a timer.

---

## 5. Adapter Library Choice

### Decision matrix

| Concern | `exqlite` direct | `ecto_sqlite3` / `ecto_sql` |
|---|---|---|
| v0.3 written dependency rule | **Conflict:** `docs/02` says `tet_store_sqlite -> tet_core, ecto_sql, sqlite adapter` | **Compliant** with `docs/02_dependency_rules_and_guards.md` |
| SQLite single-writer fit | Excellent; explicit connection ownership and no write pool by default | Acceptable only with strict repo/pool discipline: writer repo/pool size 1, separate reader repo/pool or explicit connections |
| Runtime migrations without Mix | Straightforward custom SQL runner | Must not rely on `mix ecto.migrate`; use in-app runner or `Ecto.Migrator` carefully in release |
| Release closure size | Small NIF wrapper | Larger: `ecto`, `ecto_sql`, `db_connection`, `decimal`, `exqlite` transitively |
| Phoenix/Plug/Cowboy risk | Expected none | Expected none, but must verify; `ecto_sql` does not imply Phoenix |
| Backup API | Direct SQLite backup API possible if exposed | May need direct Exqlite access or `VACUUM INTO` for backup snapshot |
| Query ergonomics | Raw SQL; exactly what we need for WAL/PRAGMA discipline | Ecto schemas/queries available, but can tempt developers into a Postgres-style pool. Do not. |
| Behaviour mapping | Manual, explicit | Ecto changesets/schemas possible, but domain structs still live in `tet_core` |

### Cross-agent confirmation from `agent-platform-architect`

Asked: whether v0.3 permits direct `exqlite` or requires `ecto_sqlite3` for consistency with optional Postgres.

Verbatim decisive excerpt:

> “The v0.3 plan does **not** specify or bless a direct raw-`exqlite` adapter interface for `tet_store_sqlite`. The controlling dependency rule is §02:
>
> `tet_store_sqlite  -> tet_core, ecto_sql, sqlite adapter`
>
> `tet_store_postgres-> tet_core, ecto_sql, postgrex`
>
> That means the intended design is: `tet_store_sqlite` depends on `tet_core`, `ecto_sql`, and an **Ecto SQLite adapter** — practically `ecto_sqlite3` unless an ADR chooses another Ecto-compatible SQLite adapter.”

Full response is captured in the appendix (§17).

### Recommendation

There is a real spec tension here:

- SQLite-owner technical preference: raw `exqlite` is the better fit for one writer, custom migrations, PRAGMAs, WAL checkpointing, and a small standalone closure.
- v0.3 platform-architecture reading: current docs require `ecto_sql` + SQLite adapter (`ecto_sqlite3`) unless an ADR/spec amendment approves raw `exqlite`.

**Phase 2 must not edit deps until the user chooses one of these paths:**

1. **Strict v0.3-compliant path (recommended if no ADR):** use `ecto_sqlite3`, configure a single writer repo/connection (`pool_size: 1` or one checked-out writer), separate small reader pool, no `mix ecto.migrate` at runtime, all PRAGMAs explicitly verified per connection, and closure-check after dependency change.
2. **SQLite-specialist path (requires ADR/spec amendment):** use raw `exqlite`, keep migration runner and writer fully explicit, document why this intentionally departs from `docs/02`, and closure-check after dependency change.

Do not split the difference by using an Ecto-style write pool. That breaks single-writer discipline and will produce `SQLITE_BUSY` storms under load. SQLite serializes writes; a pool just makes the queue chaotic.

---

## 6. Single-Writer Architecture

### Process diagram

```text
Tet.Application
└── Tet.Store.Supervisor                         (runtime-owned adapter slot)
    └── Tet.Store.SQLite.Supervisor              (owned by tet_store_sqlite)
        ├── Startup/Migration barrier             :transient or synchronous init
        ├── Writer GenServer                      :permanent, exactly one writer connection
        ├── Reader pool                           :permanent, 3–5 reader connections, WAL readers
        ├── Checkpointer                          :permanent, checkpoint connection
        └── Vacuum/maintenance scheduler          :permanent, incremental only
```

### Cross-agent input from `otp-runtime-architect`

Asked where the single writer should sit, who owns it, restart strategy, and backpressure.

Verbatim decisive excerpt:

> “Put the SQLite single-writer GenServer **inside the `tet_store_sqlite` adapter supervision subtree**, and mount that subtree under `Tet.Store.Supervisor`.
>
> Do **not** host the writer directly under `tet_runtime`.
>
> Do **not** start it as an always-on independent `tet_store_sqlite` application supervisor that runs regardless of the configured store adapter.”

Additional guidance from that response:

- `tet_runtime` owns boot ordering and adapter selection.
- `tet_store_sqlite` owns SQLite internals: writer process, migrations, WAL configuration, transaction boundaries, JSONL import batching, and SQLite-specific failure handling.
- Recommended strategies:
  - `Tet.Application`: `:one_for_one` (per v0.3 diagram).
  - `Tet.Store.Supervisor`: `:one_for_one` adapter slot.
  - `Tet.Store.SQLite.Supervisor`: `:rest_for_one` if ordered dependencies matter.
  - writer restart: `:permanent`.
  - migration one-shot: `:transient` if supervised, or synchronous barrier before writer starts.
- Backpressure: bounded `GenServer.call` timeouts, mailbox soft/hard thresholds, chunked JSONL import, reject/coalesce non-critical writes, never drop critical journal writes silently.

Full response is captured in the appendix (§17).

### Writer contract

- Exactly one writer process per workspace DB.
- All write operations go through serialized writer calls.
- Each write transaction should use `BEGIN IMMEDIATE` or equivalent writer-owned transaction start so lock acquisition happens before mutation work.
- Reads do **not** go through the writer; they use reader pool connections in WAL mode.
- Writer accepts external traffic only after:
  1. local path verification passes,
  2. writer connection PRAGMAs and WAL verification pass,
  3. crash-recovery checkpoint/integrity check passes,
  4. migrations finish,
  5. JSONL import, if needed, reaches a durable completed/skipped state,
  6. reader pool opens.

### BUSY / LOCKED handling

- `PRAGMA busy_timeout = 5000` on every connection is the first guard.
- Because all in-process writes funnel through one writer, `SQLITE_BUSY` from normal internal writes should be rare. If it is common, someone added a second writer or an external process is touching the DB.
- Treat `SQLITE_BUSY` / `SQLITE_LOCKED` after timeout as `{:error, :store_busy}` or a more specific stable store error. Do not spin unbounded retry loops.
- Event `seq` conflicts on `(session_id, seq)` should be retried inside the writer transaction loop, but with a low retry bound; a conflict under a single writer usually means a bug or external writer.
- Checkpoint operations use their own connection but are scheduled so a slow checkpoint does not block the writer mailbox. WAL docs: sqlite.org/wal.html.

### Mailbox-bounding and backpressure plan

Minimum Phase 2 design:

| Category | Policy |
|---|---|
| Critical writes | Workflow journal, approvals, artifacts metadata, final messages, durable events. Use bounded synchronous calls; never silently drop. |
| Coalescible writes | Progress/status chatter, high-volume provider deltas if runtime chooses not to persist every token. Coalesce or reject under pressure. |
| JSONL import | Chunked transactions: e.g. 100–1,000 records or 256KB–2MB decoded payload per call; never enqueue one message per JSONL line. |
| Queue monitoring | Track `:message_queue_len` and emit telemetry/log warning above soft threshold; reject non-critical writes above hard threshold. |
| Timeouts | No casual `:infinity`. Use operation-specific call timeouts; migration chunks can have longer explicit timeouts. |

Boundary callout: exact store error atoms belong in `tet_core` / `elixir-programmer` if they become part of `Tet.Store` contract.

---

## 7. Migration Runner

### Runtime rule: no Mix

Standalone releases do not ship Mix. Therefore:

- No `mix ecto.migrate` at runtime.
- No migration code that assumes Mix tasks, source files, or dev-only paths.
- Migrations are embedded in the application as ordered SQL or modules.
- A startup task or synchronous supervisor barrier runs migrations before writer traffic is accepted.

Citation: `docs/02_dependency_rules_and_guards.md` and `docs/08_release_profiles_testing_acceptance.md` keep the standalone release CLI-first and Phoenix-free; `upgrades/19_migration_path.md` says schema version is part of store migration discipline.

### Migration table

```sql
CREATE TABLE IF NOT EXISTS schema_migrations (
  version     INTEGER PRIMARY KEY,
  name        TEXT NOT NULL,
  applied_at  INTEGER NOT NULL
);
```

Optional Phase 2 addition: `checksum TEXT NOT NULL` if migrations are stored as text and checksums are cheap. If added, changing applied migration text must fail boot rather than “probably fine” its way into a corrupt schema history.

### Algorithm

1. Open writer connection.
2. On a new DB before user tables: `PRAGMA auto_vacuum = INCREMENTAL;`.
3. Apply per-connection PRAGMAs and verify WAL.
4. Ensure `schema_migrations` exists.
5. Read applied versions.
6. Compare with embedded migration list.
7. If DB has a version greater than application knows: refuse to start with `:schema_too_new` and tell user to upgrade/downgrade via backup restore.
8. For each pending migration in order:
   - `BEGIN IMMEDIATE;`
   - run DDL/DML;
   - insert `schema_migrations` row;
   - `COMMIT;`
9. If any migration fails: `ROLLBACK`, refuse startup, emit a clear diagnostic.
10. Only after migrations and import are done does the writer accept user write calls.

### Idempotency

- Migration application is version-gated by `schema_migrations`.
- Individual DDL should prefer `CREATE TABLE IF NOT EXISTS` / `CREATE INDEX IF NOT EXISTS`, but version tracking is the primary idempotency guard.
- JSONL import uses `legacy_jsonl_imports` plus deterministic/unique row keys to make interrupted import re-runnable.
- A migration that partly applied but did not commit is rolled back by SQLite transaction semantics. If a process dies mid-transaction, SQLite recovery replays/rolls back before the next open.

### Failure handling

- Migration failure means the adapter refuses to start. It does not limp along on an unknown schema.
- Crash during migration: next boot runs crash recovery, integrity check, reads `schema_migrations`, and re-attempts pending migrations if safe.
- Full destructive `down` is a dev convenience only. Production rollback is restore from a verified backup.

---

## 8. Redaction Call-Site

### Cross-agent input from `secrets-redaction-auditor`

Asked where `Tet.Redactor` should run for artifacts and event payloads, whether redaction belongs at the store boundary or inside the adapter, and which payloads must never persist.

Verbatim decisive excerpt:

> “Layer-2 redaction belongs in `tet_runtime`, upstream of every `Tet.Store` callback. Caller's responsibility. (§14 / Layer 2 — Outbound; R1.6.)
>
> The SQLite adapter must not redact. It MAY run an invariant tripwire (detector, not transformer) in `:dev`/`:test` builds.”

Additional invariants from the response:

- Provider payload and prompt-debug artifacts are post-Layer-1 by construction.
- `stdout`/`stderr` artifacts are post-Layer-2 by construction.
- The adapter may detect unredacted patterns in dev/test and raise, but must not silently mutate stored content.
- Raw API keys, OAuth refresh tokens, provider credentials, pre-redaction provider payloads, pre-redaction verifier output, authorization headers, DB URLs with passwords, and audit row content fields must never be persisted.
- The one explicit carve-out is the placeholder→original mapping required by §14 for Layer-1 idempotency and patch redacted-region rejection; it must live only in workflow journal internals, never events/artifacts/audit/log/display.

Full response is captured in the appendix (§17).

### Adapter design rule

`tet_store_sqlite` persists what `tet_runtime` hands it. It does not become a second redactor. Duplicating redaction in three store adapters masks caller bugs and breaks the §14 layered model. The SQLite adapter can provide a dev/test tripwire such as “redactor would have matched this payload; fail test,” but production transformation belongs upstream.

Boundary callouts:

- Redaction call placement in runtime belongs to `secrets-redaction-auditor` / `elixir-programmer` / runtime implementers.
- SQLite owns only the invariant that persisted bytes are whatever the core/runtime contract says is safe to persist, plus optional dev/test detection.
- Telemetry/log payloads for store queries must never include bound parameters or row contents; coordinate with `observability-engineer` in Phase 2.

---

## 9. Backup & Restore

### Backup discipline

Never raw-copy `.tet/tet.sqlite` while the runtime is open. In WAL mode, the live database state is a coordinated main DB + `-wal` + `-shm` set. A naive `cp` can capture a torn snapshot. This will restore beautifully right up until the day it ruins your afternoon. Use SQLite’s online backup API or `VACUUM INTO`.

Citations:

- sqlite.org/backup.html — online backup API.
- sqlite.org/lang_vacuum.html#vacuuminto — `VACUUM INTO` creates a transactionally consistent compact copy.
- sqlite.org/wal.html — WAL sidecar files and checkpointing.

Recommended backup flow:

1. Ask writer for a backup barrier: drain prior writes; future writes may continue if using online backup, or briefly pause for `VACUUM INTO` depending on chosen implementation.
2. Ensure destination directory `.tet/backups/` exists.
3. Create temp destination: `.tet/backups/tet-YYYYMMDD-HHMMSS.sqlite.tmp`.
4. Use either:
   - `sqlite3_backup_*` via `exqlite` if available; or
   - `VACUUM INTO '...tmp'` for a consistent snapshot.
5. Open the copy and run PRAGMAs sufficient for read/check plus `PRAGMA integrity_check;`.
6. Rename temp to final atomically.
7. Optionally compress the backup file after verification. Never compress the live DB.

If `ecto_sqlite3` is selected and does not expose SQLite backup APIs directly, prefer `VACUUM INTO` unless Phase 2 deliberately reaches through to Exqlite. Do not invent raw file-copy backup helpers.

### Restore flow

1. Stop the runtime entirely.
2. Move existing `.tet/tet.sqlite`, `.tet/tet.sqlite-wal`, `.tet/tet.sqlite-shm` aside; do not delete first.
3. Copy the verified backup to `.tet/tet.sqlite`.
4. Boot. Startup crash recovery runs path verification, PRAGMAs, WAL, suspicious WAL checkpoint, `integrity_check`, migrations, reader pool startup.
5. After successful boot and user validation, archive or remove moved-aside files.

### File-locking refusal and platform notes

SQLite locking is real. Treating SQLite like a random file on NFS is how you get corruption wearing a polite smile.

- macOS APFS: supported. Refuse paths under iCloud Drive / `~/Library/Mobile Documents/` unless an explicit override exists; eviction/sync semantics are not a database VFS.
- Linux ext4/xfs/btrfs: supported.
- Linux tmpfs: technically works but evaporates on reboot. Refuse or warn unless `TET_ALLOW_TMPFS=1` is set.
- Windows NTFS: SQLite supports platform locking; document but do not optimize first.
- NFS/SMB/CIFS/sshfs/fuse network mounts: refuse startup. SQLite docs warn that network filesystems commonly break locking assumptions (sqlite.org/lockingv3.html and sqlite.org/faq.html#q5).

Startup should use `statfs` / `df -T` / `mount` heuristics to reject obvious `nfs`, `smbfs`, `cifs`, `fuse.sshfs`, and similar mount types. False negatives are possible; document the supported platform matrix.

---

## 10. Crash Recovery (boot path)

This is the storage-adapter boot path, not the workflow recovery decision tree. It runs before `Tet.Runtime.WorkflowRecovery` consumes journal state.

Citation: `diagrams/crash_recovery.mmd` says workflow recovery runs after `Tet.Store.Supervisor` is up and before `WorkflowSupervisor` accepts new workflows. `upgrades/12_durable_execution.md` makes the journal source of truth.

### 8-step boot checklist

1. **Resolve DB path**: canonical absolute path for `<workspace>/.tet/tet.sqlite`; reject network mounts / unsupported paths before open.
2. **Open writer connection**: create `.tet/` if needed; if DB is new, set `PRAGMA auto_vacuum = INCREMENTAL` before any user tables.
3. **Apply PRAGMA block and verify WAL**: fail startup if `PRAGMA journal_mode;` is not `wal`.
4. **Suspicious WAL checkpoint**: if `.tet/tet.sqlite-wal` exists and is `>64MB` or older than the main DB file, run `PRAGMA wal_checkpoint(RESTART);` before integrity check.
5. **Integrity check**: run `PRAGMA integrity_check;`; anything other than `ok` is a startup failure with backup-restore instructions.
6. **Migrations and JSONL import**: read `schema_migrations`, run pending migrations, then run/skip one-time legacy JSONL import using `legacy_jsonl_imports`. Failure refuses startup.
7. **Open reader pool and maintenance processes**: each reader gets the full PRAGMA block; start checkpointer and incremental vacuum scheduler after schema is current.
8. **Signal ready / accept traffic**: only now may writer accept external calls and only now may runtime workflow recovery start consuming journal rows.

### `wal_checkpoint(RESTART)` timing

Run on boot only when suspicious WAL criteria are met. Normal bounded WAL maintenance uses periodic `PRAGMA wal_checkpoint(TRUNCATE)` every 1000 writes or 60 seconds (configurable), logged with duration and warnings above 500ms.

### `integrity_check` timing

Run before migrations. Migrating a corrupt DB is just adding fresh paint to a cracked foundation. If `integrity_check` fails, stop and point the user at restore.

### Traffic acceptance

No store callback should enqueue work to the writer before boot readiness. If a caller races startup, return `{:error, :store_not_ready}` or block behind a bounded startup barrier; do not accept writes into an un-migrated DB.

---

## 11. Cutover Plan

### Legacy files to handle

Current real workspaces may have:

```text
.tet/messages.jsonl
.tet/events.jsonl
.tet/autosaves.jsonl
.tet/prompt_history.jsonl
```

Current config also defaults to:

```elixir
config :tet_runtime,
  store_adapter: Tet.Store.SQLite,
  store_path: ".tet/messages.jsonl"
```

The v0.3 default must become:

```text
.tet/tet.sqlite
```

### Recommended approach: one-time idempotent importer

Recommendation: **one-time importer on first SQLite boot; no fallback-read dual source.**

Why:

- Fallback-read for one release creates two sources of truth and ambiguous ordering between JSONL and SQLite. That is how old data becomes immortal in the wrong file.
- Hard cutover with manual migration risks users losing scaffold-era workspaces.
- A startup importer is deterministic, idempotent, and keeps the `Tet.Store` seam intact for callers.

### Import algorithm

1. Resolve workspace root and target DB path.
2. If DB is absent/new and legacy JSONL files exist, create DB and migrate schema first.
3. For each legacy file kind:
   - compute size, mtime, sha256;
   - check `legacy_jsonl_imports` for matching `(source_kind, source_path, sha256)`;
   - if already imported, skip;
   - parse line-by-line with the same core `from_map` functions used today;
   - insert in chunks inside writer transactions;
   - insert/replace import ledger row only after the file’s import commits.
4. Do not delete legacy JSONL files. Optionally write `.tet/legacy_jsonl_imported.json` as a human-readable sentinel.
5. After successful import, all runtime reads/writes use SQLite only.

### Mapping rules

| Legacy record | Import mapping |
|---|---|
| Message | Preserve `message.id`, `session_id`, `role`, `content`, metadata. Allocate message `seq` by JSONL order within session. Create/update workspace and session rows as needed. |
| Session | Derived from messages, matching current `Tet.Session.from_messages/2`; v0.3 session columns get safe defaults (`mode='chat'`, `status='idle'`, provider/model null, generated/derived short id). |
| Event | Current `Tet.Event` has no `id`; generate deterministic event id from source kind/path/line number/sha. Preserve `sequence` if present and valid per session, otherwise allocate in JSONL order. |
| Autosave | Preserve checkpoint id, session id, saved_at, messages/attachments/debug fields into `autosaves`. Create session shell if missing but flag in metadata. |
| Prompt history | Preserve id/version/created_at/request/result/metadata into `prompt_history_entries`. |

### Legacy path compatibility

For one transition release, if `TET_STORE_PATH` or `:store_path` ends in `.jsonl`, treat it as a **legacy import source**, not the new DB path. Derive the DB path as `Path.join(Path.dirname(store_path), "tet.sqlite")` unless an explicit `:db_path` / new `TET_SQLITE_PATH` is provided. This avoids making every existing test/user config fail immediately.

Open question for user: should Phase 2 introduce a new `TET_SQLITE_PATH`, repurpose `TET_STORE_PATH`, or support both for one release? Recommendation: support both for one release, but document `.tet/tet.sqlite` as the default.

### Backward-compat test strategy

- Fixture with all four JSONL files imports into empty DB.
- Re-running importer produces no duplicate rows.
- Import interrupted mid-file resumes or retries without duplicates.
- Imported `Tet.Message`, `Tet.Event`, `Tet.Autosave`, and `Tet.PromptLab.HistoryEntry` round-trip through current callbacks.
- Legacy `.jsonl` files remain unchanged after import.
- New writes after import go only to SQLite.

---

## 12. Test Strategy

Citation: `upgrades/18_test_strategy.md` defines L1–L7, including L4 runtime/store contract tests and L5 crash/recovery integration tests.

### Test isolation

- Every SQLite test uses a unique temp workspace root and `.tet/tet.sqlite` under it.
- No tests share repo-root `.tet/`.
- No test uses `~/.tet` or `/var`.
- Tests must clean up DB, `-wal`, `-shm`, and `.tet/artifacts/` sidecars.

### Contract tests

Blocking prerequisite: there is currently no `apps/tet_store_memory/` in this repository listing and no visible shared store contract suite. v0.3 requires the same suite to run against memory, SQLite, and optional Postgres (`docs/08`, `upgrades/18`). Phase 2 should not claim parity based only on adapter-local tests.

Required contract coverage:

- Current callbacks: messages, sessions, autosaves, events, Prompt Lab history, health/boundary.
- Future v0.3 callbacks once added: workspace/session/task/tool/approval/artifact/event operations, transactions, workflow journal operations.
- Store errors for missing rows, duplicate invariants, invalid FK references, and busy/locked conditions.

### SQLite-specific tests

- PRAGMA verification: WAL engaged; foreign_keys on; busy_timeout set; cache_size negative semantics.
- Network-mount heuristic unit tests with mocked mount output.
- Single-writer serialization property: many concurrent callers append events/messages; resulting `seq` is gap-free per session.
- `approvals_one_pending_per_session`: concurrent pending approvals result in one success and one constraint error.
- Artifact inline/spill threshold: `<16KB` inline, `>=16KB` path; sha dedup; tmp-rename atomicity.
- WAL checkpoint cadence: checkpoint called by write-count and timer knobs; long duration logged.
- Incremental vacuum task calls `PRAGMA incremental_vacuum(N)` and never full `VACUUM` on a timer.
- Backup snapshot integrity: backup copy passes `PRAGMA integrity_check`.

### JSONL cutover tests

- Import messages/events/autosaves/prompt history from legacy files.
- Re-run import idempotently.
- Preserve current callback behaviour for `Tet.Store.SQLitePromptHistoryTest` semantics: prompt-history persistence does not create message/autosave/event artifacts unnecessarily.
- Legacy `.jsonl` remains read-only after import.

### Crash-recovery tests

Per `upgrades/18_test_strategy.md` L5 and `diagrams/crash_recovery.mmd`:

- Kill BEAM after schema migration begins but before commit; restart reruns cleanly.
- Kill BEAM during JSONL import chunk; restart imports without duplicates.
- Kill BEAM with large WAL; restart triggers checkpoint when criteria match.
- Corrupt copy / failed `integrity_check` refuses startup.
- Workflow journal recovery tests belong with runtime once `workflow_steps` callbacks exist.

### Property / fuzz tests

- Event append property: for arbitrary interleavings of append requests through the writer, each session’s `seq` is contiguous and ordered by commit.
- Artifact content property: stored sha256 always matches inline/file bytes.
- Import property: random valid JSONL records imported then listed equal core struct normalization.
- Redaction property belongs upstream: provider payload artifacts contain no planted secrets with adapter tripwire disabled, proving runtime redaction happened before store.

---

## 13. Release-Closure Verification

### Current state

`apps/tet_store_sqlite/mix.exs` currently has only:

```elixir
{:tet_core, in_umbrella: true}
```

No dependency changes are made in Phase 1. Therefore no `mix deps.get`, no closure run, and no claims based on new dependency trees in this design phase.

### Required Phase 2 checks after dependency choice

After any `apps/tet_store_sqlite/mix.exs` dependency change, run both:

```bash
MIX_ENV=prod mix deps.tree --only prod | grep -E 'phoenix|plug|cowboy|live_view|bandit' \
  && echo "❌ FORBIDDEN DEP IN STORAGE CLOSURE" \
  || echo "✅ closure clean"
```

and:

```bash
tools/check_release_closure.sh
```

`tools/check_release_closure.sh` builds `tet_standalone` unless called with `--no-build`, then checks `_build/prod/rel/tet_standalone/lib` and release metadata for forbidden web-framework apps including Phoenix, Plug, Cowboy, Bandit, LiveView, WebSock, and `tet_web*`.

### Expected closure by adapter option

- `exqlite`: expected closure is `tet_core`, `tet_store_sqlite`, `exqlite`/NIF build helpers, and OTP libraries; no Phoenix/Plug/Cowboy expected. Must verify.
- `ecto_sqlite3`: expected closure includes `ecto`, `ecto_sql`, `db_connection`, `decimal`, telemetry-related deps, SQLite adapter, and `exqlite` transitively; no Phoenix/Plug/Cowboy expected. Must verify.

If grep finds `phoenix`, `plug`, `cowboy`, `live_view`, or `bandit`, revert the dependency change. No “just for dev” exceptions in `tet_store_sqlite` release closure.

Citation: `docs/02_dependency_rules_and_guards.md` Gate B1/B5 and root `mix.exs` `@forbidden_standalone_*` lists.

---

## 14. Phased Implementation Sequence

Mapping this design to the requested six-phase roadmap:

| Phase | Scope | Estimated size | Cross-agent input needed |
|---:|---|---:|---|
| 1 | Discovery & design | Done by this document | User review; dependency decision |
| 2 | Dependency + connection foundation | Medium | `agent-platform-architect` / user decide `ecto_sqlite3` vs ADR for `exqlite`; `otp-runtime-architect` for final child specs |
| 3 | Schema + migration runner | Large | `elixir-programmer` if `Tet.Store` behaviour expands first; `observability-engineer` for migration telemetry |
| 4 | Adapter callback implementation + single writer/readers | Large | `elixir-programmer` for domain mapping; `secrets-redaction-auditor` for dev/test tripwire semantics |
| 5 | JSONL importer + artifact store + backup/recovery/checkpoint/vacuum | Large | `cli-engineer` for future `tet backup` / `tet migrate` UX; `otp-runtime-architect` for startup barrier and readiness |
| 6 | Shared contract tests + crash tests + closure hardening | Medium-large | `qa-expert` or `elixir-programmer` for shared store contract suite; `observability-engineer` for telemetry assertions |

### Phase 2 detail: dependency + connection foundation

- Choose adapter library.
- Add dependency only after user approval.
- Implement DB path resolution to `.tet/tet.sqlite` while supporting legacy `.jsonl` import sources.
- Implement path/mount refusal scaffolding.
- Implement connection open + PRAGMA verification.
- Introduce writer supervisor skeleton, but do not claim feature completeness until migrations and callbacks land.

### Phase 3 detail: schema + migration runner

- Embed ordered migrations.
- Set `auto_vacuum = INCREMENTAL` on new DB before tables.
- Create v0.3 tables and compatibility tables.
- Record `schema_migrations`.
- Fail fast on migration/integrity errors.

### Phase 4 detail: callbacks

- Implement current `Tet.Store` callbacks without changing callers.
- Add transaction/write serialization.
- Implement event `seq` allocation.
- Implement reader pool query paths.
- Preserve current return structs only; no SQLite handles leak upward.

### Phase 5 detail: import and operations

- Import legacy JSONL idempotently.
- Implement artifact inline/spill policy.
- Implement backup via online API or `VACUUM INTO`.
- Implement WAL checkpoint and incremental vacuum cadence.
- Implement startup crash-recovery boot sequence.

### Phase 6 detail: tests and hardening

- Build shared contract suite or block until it exists.
- Rewrite existing JSONL-path tests to SQLite temp DBs plus legacy-import fixtures.
- Add concurrency/property tests.
- Run closure checks after deps.
- Add docs/README updates.

---

## 15. Open Questions for User

| # | Question | Options | Recommendation |
|---:|---|---|---|
| 1 | Adapter library: strict v0.3 `ecto_sqlite3` or ADR-approved raw `exqlite`? | A: `ecto_sqlite3` for spec compliance. B: raw `exqlite` with ADR/spec amendment. | If no ADR appetite, choose A. If optimizing standalone closure/control is more important, approve B explicitly. Do not proceed with deps until decided. |
| 2 | Should Phase 2 implement current `Tet.Store` only, or update `tet_core` to v0.3 callbacks first? | A: current callbacks + v0.3 schema. B: behaviour update first. | B is cleaner for final architecture but owned by `elixir-programmer`. A is safer incremental cutover if timeline matters. |
| 3 | ID strategy: preserve current prefixed IDs or switch core/runtime to UUIDv4 now? | A: store accepts current `ses_`/`msg_`. B: change generators/structs to UUIDv4. | Use `TEXT` now either way; coordinate B before adding strict UUID checks. |
| 4 | Event `session_id` nullability | A: require `session_id NOT NULL` per per-session timeline. B: allow workspace/global events with nullable session. | Require NOT NULL for Phase 2 to preserve per-session `seq`; ask `elixir-programmer` how workspace events should be represented. |
| 5 | Approval terminal status spelling | Locked: v0.3 §04 and user decision use `:rejected`; `:denied` is not canonical. | Encode only `rejected` in core expectations and future CHECK constraints. Do not accept both unless a later migration ADR explicitly requires compatibility. |
| 6 | Legacy env/path semantics | A: repurpose `TET_STORE_PATH` to DB path immediately. B: support legacy JSONL path for one release and derive DB path. C: introduce `TET_SQLITE_PATH`. | B + optional C for one release. Hard break is unnecessary. |
| 7 | Autosave and Prompt Lab history | A: keep compatibility tables. B: move callbacks out of `Tet.Store`. | Keep compatibility tables until `tet_core` behaviour changes; callers exist now. |
| 8 | Placeholder→original secret mapping retention | A: store plaintext mapping in workflow journal per §14 and purge by workflow lifecycle. B: reject this and revise redaction plan. | Follow §14 but require retention/purge design with secrets auditor + OTP architect. Be honest that `.tet/tet.sqlite` at rest contains this carve-out. |
| 9 | Backup UX | A: storage module only. B: CLI command in Phase 2/5. | Storage implements safe primitive; `cli-engineer` owns user command. |
| 10 | Tmpfs policy | A: refuse tmpfs unless override. B: allow with warning. | Refuse unless `TET_ALLOW_TMPFS=1`; durability is the product requirement. |

---

## 16. Risks & Mitigations

| Risk | Impact | Likelihood | Mitigation |
|---|---:|---:|---|
| Adapter-library conflict stalls Phase 2 | High | Medium | User chooses strict `ecto_sqlite3` or approves ADR for `exqlite` before any dep edit. |
| Multiple writers accidentally introduced | High | Medium | One writer process supervised under adapter subtree; no write pool; tests assert serialized seq; code review gate. |
| WAL fails to engage and adapter silently runs rollback journal | High | Low-medium | Verify `PRAGMA journal_mode; == wal`; refuse startup otherwise. |
| Foreign keys off on a connection | High | Medium | Apply full PRAGMA block on every writer/reader/checkpoint connection; tests query `PRAGMA foreign_keys`. |
| JSONL import duplicates rows on retry | Medium-high | Medium | `legacy_jsonl_imports`, deterministic IDs where needed, unique constraints, chunk transactions. |
| Current prefixed IDs violate strict UUID DDL | High | High if ignored | Use `TEXT` without UUID length check in initial migration; coordinate ID generator change separately. |
| Event timeline loses events because runtime swallows `save_event` errors | High | Medium | Phase 2 boundary issue with runtime owner; durable timeline write failures must propagate for critical events. |
| `approval.status` mismatch (`rejected` vs `denied`) | Medium | Medium | Decide before migration; encode one canonical value in CHECK. |
| Secrets redaction mistakenly done inside adapter | Medium-high | Medium | Runtime owns redaction; adapter only dev/test tripwire; shared tests with tripwire disabled. |
| Raw `cp` backup shipped | High | Low if reviewed | Only online backup / `VACUUM INTO`; docs and tests reject helper named/implemented as raw copy. |
| NFS/SMB workspace corrupts DB | High | Medium | Startup mount heuristics refuse network filesystems; docs cite sqlite.org/lockingv3.html and FAQ q5. |
| Release closure pulls Phoenix/Plug/Cowboy | High | Low-medium | Run deps tree grep and `tools/check_release_closure.sh` after deps; revert on hit. |
| Shared store contract suite missing | Medium-high | High current | Flag as Phase 2/6 prerequisite; adapter-local tests are not enough. |
| Long WAL / pinned readers cause checkpoint stalls | Medium | Medium | Periodic checkpoint with duration logging; alert above 500ms; tune reader query lifetimes. |
| Full `VACUUM` blocks runtime | Medium | Medium if someone gets clever | Runtime uses incremental vacuum only; full vacuum is manual maintenance command. |
| Ecto repo pool accidentally becomes a write pool | High | Medium if `ecto_sqlite3` chosen | Configure writer pool size 1 / single writer GenServer; separate readers; tests simulate concurrent writes. |
| Prompt Lab/autosave compatibility forgotten | Medium | Medium | Include compatibility tables and tests until behaviour changes. |

---

## 17. Appendix — Cross-Agent Responses Captured

### `otp-runtime-architect` response summary / key verbatim excerpts

Session: `otp-runtime-architect-session-c70ee9`

> “Put the SQLite single-writer GenServer **inside the `tet_store_sqlite` adapter supervision subtree**, and mount that subtree under `Tet.Store.Supervisor`.
>
> Do **not** host the writer directly under `tet_runtime`.
>
> Do **not** start it as an always-on independent `tet_store_sqlite` application supervisor that runs regardless of the configured store adapter.”

> “`tet_runtime` owns **boot ordering and adapter selection**. `tet_store_sqlite` owns **SQLite internals**, including the single-writer process, queueing semantics, migrations, WAL configuration, transaction boundaries, and SQLite-specific failure handling.”

> “Recommended: `Tet.Application: :one_for_one`; `Tet.Store.Supervisor: :one_for_one`; `Tet.Store.SQLite.Supervisor: :rest_for_one`; SQLite Writer restart `:permanent`; migration one-shot `:transient`.”

> “For JSONL→SQLite migration, do **not** enqueue one GenServer message per JSONL record if there may be many records. Prefer parse N records → writer `{:import_chunk, records}` → writer transaction inserts chunk → reply progress.”

### `secrets-redaction-auditor` response summary / key verbatim excerpts

Session: `secrets-redaction-auditor-session-2a73fa`

> “Layer-2 redaction belongs in `tet_runtime`, upstream of every `Tet.Store` callback. Caller's responsibility. (§14 / Layer 2 — Outbound; R1.6.)”

> “The SQLite adapter must not redact. It MAY run an invariant *tripwire* (detector, not transformer) in `:dev`/`:test` builds.”

> “Raw API keys, MCP tokens, OAuth refresh tokens, any long-lived credential — no Cloak field, no encrypted Ecto column, no `credentials` table.”

> “Pre-Layer-1 provider payload ‘for debugging’ — the artifact contract is post-redaction, full stop.”

> “The placeholder→original mapping is the **one** credential-shaped string that legitimately reaches durable storage in v0.3... Lives in the **workflow journal table**, NOT in `Tet.Artifact` rows, `Tet.Event` rows, `tet_audit` rows, log lines, or telemetry payloads.”

### `agent-platform-architect` response summary / key verbatim excerpts

Session: `agent-platform-architect-session-dc0bca`

> “The v0.3 plan does **not** specify or bless a direct raw-`exqlite` adapter interface for `tet_store_sqlite`. The controlling dependency rule is §02:
>
> `tet_store_sqlite  -> tet_core, ecto_sql, sqlite adapter`
>
> `tet_store_postgres-> tet_core, ecto_sql, postgrex`”

> “That means the intended design is: `tet_store_sqlite` depends on `tet_core`, `ecto_sql`, and an **Ecto SQLite adapter** — practically `ecto_sqlite3` unless an ADR chooses another Ecto-compatible SQLite adapter.”

> “Direct `exqlite` may appear **transitively** under `ecto_sqlite3`; that is fine. But making `tet_store_sqlite` directly depend on and program against raw `exqlite` instead of `ecto_sql` + SQLite adapter would be a departure from §02 and should require an ADR/spec amendment.”

---

## 18. Final Status

**READY FOR USER REVIEW**

Phase 2 should not start until the user decides the adapter-library question and confirms whether the implementation should preserve the current `Tet.Store` behaviour first or coordinate a v0.3 behaviour expansion before storage work lands.
