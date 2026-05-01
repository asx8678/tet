# 19 — Migration Path: v0.1 → v0.3

> **v0.3 introduced this doc** because v0.2 was silent on what teams
> already building against the original plan should keep, redo, or
> defer.

## Audience

You started building Tet against the original 11-doc plan
(`docs/00`–`docs/10`) and have one of these states:

- **State A:** Phase 0 complete (umbrella + guards). Nothing else.
- **State B:** Phases 0–2 complete (core + runtime foundation).
- **State C:** Phases 0–4 complete (CLI foundation works).
- **State D:** Phases 0–7 complete (execute mode + approvals work).

Each state has a different migration cost.

## What stays unchanged (all states)

- The umbrella structure and app names.
- `Tet`/`tet`/`.tet/` namespace.
- The five gates + facade-only guard + removability test.
- The dependency direction diagram.
- The mode matrix (chat / explore / execute).
- The CLI command list and exit codes.
- Public API surface for stable functions
  (`init_workspace`, `start_session`, `send_prompt`, `approve_patch`,
  `reject_patch`, `run_verification`, `subscribe`, `list_events`,
  `lookup`, `prompt_debug`, `doctor`, `get_workspace`, `get_session`,
  `list_sessions`).
- Workspace layout (`.tet/tet.sqlite`, `config.toml`, prompts,
  artifacts).

## What you must change in any case

These are the inline corrections from `upgrades/00_corrections.md`.
Whatever state you are in:

1. **Replace `String.to_atom` / `String.to_existing_atom` calls with
   `Tet.Codec`** in store adapters and any deserialization code.
   This is a small mechanical change but a real bug source.
2. **Add `Tet.cancel/2` to the facade.** Trivial.
3. **Add `schema_version()` to `Tet.Store` behaviour** and have your
   store adapters return a stable integer.
4. **Replace binary trust state with `Tet.Workspace.Trust`** struct.
   The default value (`%{state: :trusted, allow_globs: ["**"],
   deny_globs: []}`) is equivalent to today's `:trusted`, so existing
   workspaces don't break — but the schema needs the new columns.

These are non-disruptive: you can do them as the first commit on top
of your existing work.

## State A — Phase 0 done

Easiest case. Continue from Phase 0 with the v0.3 build order
(`upgrades/17_phasing_and_scope.md`):

- Phase 1: add `Tet.Workflow`, `Tet.WorkflowStep`, `Tet.Codec` to the
  core structs you build.
- Phase 2: build `WorkflowSupervisor`, `WorkflowExecutor`,
  `WorkflowRecovery` instead of `SessionWorker`.

No code thrown away.

## State B — Phases 0–2 done (you have `SessionWorker`)

`SessionWorker` is gone in v0.3. Two options:

- **Recommended:** delete `SessionWorker`, follow the v0.3 supervision
  tree (`upgrades/12_durable_execution.md` §"Supervision tree
  updates"), and rebuild dispatch as the v0.3 layout describes.
  Effort: roughly Phase 2's original size again, because the executor
  is more sophisticated than the worker — but you keep the registry,
  event bus, store supervisor, and facade.
- **Defer:** continue building chat mode as-is (Phase 5), then
  refactor to durable execution before Phase 7. This is risky because
  Phase 7's atomic-patch story is much harder without the workflow
  journal, so most teams will end up doing the work anyway.

The first option is honest about the cost. Pick it.

## State C — Phases 0–4 done (CLI works in chat mode)

You have `tet doctor`, `tet init`, `tet workspace trust`, and
`tet session new/list/show` working against an in-memory model that
doesn't yet exercise the workflow journal.

Migration:

- **Apply the universal corrections.**
- **Insert the workflow journal between the facade and your existing
  command paths.** Practically: every `Tet.Runtime.dispatch/2` call
  now opens or attaches to a workflow, the dispatch handler becomes
  the executor's first step, and you commit a step record around each
  side effect. This is invasive — plan for ~1 phase of effort.
- **Refactor the supervision tree** to drop `SessionWorker` and add
  `WorkflowSupervisor` / `WorkflowRecovery`. Sessions become pure
  data; only workflows have running processes.
- **Rebuild Phase 5 (chat) on the new substrate.** Most of the chat
  rendering and message persistence code carries over; the agent loop
  itself is rewritten as a step program.

Total: about Phase 5 worth of work, plus the universal corrections.

## State D — Phases 0–7 done (you have execute mode, approvals,
patch apply)

This is the most expensive state to migrate from, because you have
working patch logic that does not match the v0.3 atomic story.

Migration in priority order:

1. **Universal corrections.** Always first.
2. **Add the workflow journal.** Same as state C, but you'll need to
   retrofit your existing tool_run/approval/patch_apply paths to
   commit step records. Existing approval rows continue to work; the
   new journal sits beside them.
3. **Replace the patch applier with the atomic version**
   (`upgrades/12_durable_execution.md` §"Patch application"). This is
   a focused refactor: `propose_patch`, `apply_approved_patch`, and
   the rollback module. The rest of the approval flow is untouched.
4. **Add the redacted-region patch validator.**
5. **Rebuild verifier path** as `verifier_run:<name>` steps with
   journal-tracked output. Surface change is small; output capture
   moves into step output.
6. **Throw away** any "snapshot when practical" code; rollback is
   mandatory.

The patch applier rewrite is the most concerning piece of state D
migration; budget a phase of effort for it alone. The rest is
mechanical.

## What carries over verbatim (any state)

- Path policy and adversarial path tests.
- Mode policy decisions and reason atoms.
- Tool implementations for read tools (`list_dir`, `read_file`,
  `search_text`, `git_status`, `git_diff`).
- Verifier allowlist mechanics.
- CLI argv parsing and renderers.
- `.tet/` folder layout and config.toml schema.
- All five gates and the removability test.

## Data migration

If you have a populated `.tet/tet.sqlite` from pre-v0.3 work:

1. Bump the schema version in your store adapter.
2. Add migration that creates the `workflows` and `workflow_steps`
   tables.
3. Existing sessions, approvals, events, artifacts stay as-is.
4. Backfilling old activity into workflow rows is **not required**;
   pre-v0.3 sessions look like sessions with no completed workflows.
   `tet doctor` will show schema-current; old sessions are read-only
   in practice (no executor will ever attach to them).
5. New sessions after the migration use workflows from the start.

This avoids a giant backfill and accepts that pre-v0.3 sessions are
historical artifacts.

## Versioning the migration itself

The first store adapter migration that adds workflows is at schema
version N+1, where N is your current version. From there on, each
schema change increments. `tet migrate` is forward-only; rolling back
requires restoring `.tet/tet.sqlite` from backup.

If you have multiple workspaces in active development with different
schema versions, run `tet migrate` per workspace.

## Picking up extensions later

Per `upgrades/17_phasing_and_scope.md`, MCP, multi-agent profiles,
custom slash commands, model registry live updates, OS keychain,
multi-node, and editor RPC are v1.x. Once your v1 ships, you can
adopt them additively without touching the core. The workflow journal
is the load-bearing piece that makes this possible — that's why it's
v1 must-have, not v1.x.

## Risks during migration

- **Two patch appliers in flight at once** if you defer the rewrite
  past v0.3 cutover. Keep them feature-flagged behind `[execute]`
  config and bias toward the new one.
- **Schema drift between dev workspaces and CI.** Bake `tet migrate`
  into CI bootstrap so all environments converge.
- **Regression in chat throughput** during the workflow journal
  insertion. Workflow journaling is one extra row per provider
  attempt and one per tool run — not high cost, but worth measuring.
  If chat latency regresses by more than ~30ms p50, profile before
  shipping; SQLite's WAL mode and a small per-session insert batcher
  cover most cases.

## Acceptance

This doc is a planning artifact; teams confirm by:

- [ ] Reading this doc, picking their starting state, and writing
      their migration plan.
- [ ] Running the universal corrections as a single PR before any
      v0.3 feature work.
- [ ] CI green on layers L1–L4 and L6 throughout the migration.
- [ ] L5 recovery tests come online before the patch applier rewrite
      ships.
