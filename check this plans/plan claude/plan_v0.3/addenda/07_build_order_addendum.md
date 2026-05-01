# 07 — Build Order Addendum

> Updates `docs/07_build_order_migration.md` with the v0.3 phase split
> and additions. Read this alongside the original; the original phase
> intent is preserved, but several phases have new content.

## Phase 0 — Skeleton and boundary guards

**Original deliverables stand**, plus:

- `Tet.Codec` skeleton (just the allowlists and stub functions; full
  decoders land in Phase 1).
- `tools/check_imports.sh` extended with the v0.3 guards:
  - no `String.to_atom` / `String.to_existing_atom` in store adapters;
  - no `System.get_env` for credential suffixes outside `Tet.Secrets`.

Pass condition unchanged: deliberate forbidden import in
core/runtime/CLI fails CI.

## Phase 1 — Core contracts

**Original deliverables**, plus:

- Complete `Tet.Codec` (corrections §1).
- `Tet.Workflow` and `Tet.WorkflowStep` schemas (doc 12).
- `Tet.Workflow.IdempotencyKey` (doc 12).
- `Tet.Patch.Change` and `Tet.Patch.parse/1` (doc 12).
- `Tet.Workspace.Trust` struct (corrections §4).
- `Tet.LLM.Provider` behaviour with normalized event types (doc 11).
- `Tet.Secrets` behaviour (doc 14).
- `Tet.Agent.Profile` validator (extension; can be deferred to v1.x
  but the validator is small and harmless to have early).

Pass condition: core compiles with no Phoenix, Plug, Ecto, runtime,
CLI, or web references; property tests for Codec round-trip and
IdempotencyKey determinism pass.

## Phase 2 — Runtime foundation and public facade

**Replaces** the original phase content for the supervision tree.

- `Tet.Application` with the v0.3 tree
  (`addenda/01_architecture_addendum.md`).
- `Tet` facade including `Tet.cancel/2` (corrections §2).
- `Tet.Runtime.SessionRegistry` and `SessionSupervisor` (dispatch
  layer only, no per-session state).
- `Tet.Runtime.WorkflowSupervisor` and `WorkflowExecutor` (skeleton
  step program, no real steps yet).
- `Tet.Runtime.WorkflowRecovery` (no-op until journal exists; placed
  here because moving it later is more work).
- `Tet.EventBus` with workflow vs. domain event distinction (doc 12).
- `Tet.LLM.TaskSupervisor`.
- Basic `Tet.doctor` returning shape-only checks.

Drop: `Tet.Runtime.SessionWorker`, `Tet.Agent.RuntimeSupervisor`.

Pass condition: runtime starts without endpoint; facade can create/get
a test session via memory store; an empty workflow executes and
commits zero steps cleanly.

## Phase 3 — Storage adapters and workspace init

**Original deliverables**, plus:

- Workflow journal store contract (`start_step`, `commit_step`,
  `fail_step`, `cancel_step`, `claim_workflow`,
  `list_pending_workflows`, `list_steps`, `schema_version`).
- Memory and SQLite implementations of all the above.
- Migrations for `workflows` and `workflow_steps` tables in SQLite.
- `tet doctor` schema-version check.
- `tet migrate` command (doc 13).

Pass condition: `tet init .` creates local workspace store; events
and sessions persist; workflow journal contract tests pass on memory
and SQLite; schema-version mismatch is caught with a clear message.

## Phase 4 — CLI foundation

**Original deliverables**, plus:

- `--json` mode infrastructure (doc 16): each command returns
  structured data; renderers transform to human or JSON.
- `tet help`, `tet --version`, `tet --license` generated from a
  single source.
- Verbosity flags (`-q`, `-v`, `-vv`).
- NO_COLOR / TTY detection.

Pass condition: CLI boots and initializes workspace with no Phoenix
dependency; `--json` parity tests pass.

## Phase 5a — Provider contract

**New phase split.** This was originally part of Phase 5; the v0.3
plan separates the provider work because it now gates everything
else.

- `Tet.LLM.Providers.Anthropic` adapter.
- `Tet.LLM.Providers.OpenAICompatible` adapter.
- Tool-call bidirectional map for both (doc 11).
- Retry/timeout/stream-stall machinery with the 250ms floor.
- Bundled `priv/models.json` registry.
- `tet model list` and `tet model show`.

Pass condition: provider conformance tests (L3 in doc 18) pass for
both adapters against recorded fixtures; tool-call round-trip
property tests pass.

## Phase 5b — Chat mode

**Original Phase 5 deliverables**, now wired through workflows.

- `compose_prompt` step (pure but journaled).
- `provider_call:attempt:N` step.
- `Tet.Prompt.Composer` with system/mode/agent layers and AGENT.md
  loading (extension; the file-loading hook is here even if AGENT.md
  itself is v1.x).
- Redaction layer 1 (doc 14): tool-output redaction before adding to
  conversation.
- Message persistence as journal step `emit_event`.
- `tet chat`, `tet ask`, `tet prompt debug`.
- `Ctrl-C` cancellation in `tet chat` (doc 16).

Pass condition: user can chat from terminal; messages and events
persist; provider errors become events without crashing the runtime;
SIGINT cancels in-flight prompt.

## Phase 6 — Explore mode and read tools

**Original deliverables**, plus:

- Per-path trust globs (corrections §4).
- `Tet.Workspace.Trust` honored in path policy.

Pass condition: inside-root reads work; outside-root and symlink
escapes are blocked; deny-globs override allow-globs in property
tests.

## Phase 7 — Execute mode, patches, approvals

**Significantly revised.** The atomic patch story replaces the
original "snapshot when practical."

- `propose_patch` as `tool_run:propose_patch` step.
- Diff parser producing `Tet.Patch.Change` records.
- Snapshot phase writing `manifest.json` atomically.
- `git apply --check` dry run.
- `git apply` (no `--index` by default; opt-in via config).
- Per-change-type rollback (doc 12 §"Rollback by change type").
- Redacted-region patch validator (doc 14).
- `tet edit`, `tet approvals`, `tet patch approve`, `tet patch reject`.
- `tet cancel`.

Pass condition: patch is proposed as diff; user sees approval in CLI;
approved patch changes files atomically; rejected patch changes
nothing; untrusted workspace cannot write; recovery restores torn
patches.

## Phase 8 — Verification loop

**Original deliverables**, plus:

- `verifier_run:<name>` step.
- Allowlist env scrubbing (doc 14 §"Verifier env scrubbing").
- Stdout/stderr artifacts produced and stored as journal step output.
- Layer 2 redaction on artifacts before persistence.

Pass condition: approved patch can trigger verifier; failed verifier
returns exit code 6 and does not corrupt approval state.

## Phase 9 — Hardening

**Original deliverables**, plus:

- Property + fuzz suites per doc 18 layer L2.
- Crash + recovery integration tests per doc 18 layer L5.
- `tet doctor --network`.
- `tet audit export`.

Pass condition: full v0.3 acceptance checklist passes.

## Phase 10 — Optional Phoenix adapter

**Original deliverables stand.**

LiveView reconnects re-derive state from the workflow journal via
`Tet.list_events/2` and `Tet.subscribe/1` — the journaled execution
makes this clean, since events are projections of durable state.

## Phase 11 — Release profiles

**Original deliverables stand.** The release closure check now also
verifies no Bandit / Plug / Cowboy in `tet_standalone` even
indirectly through telemetry exporters (doc 13 dropped the Bandit
Prometheus exporter; this is the gate that enforces it).

## Phase 12 — Operational hardening

**New phase, v1.**

- All telemetry events from doc 13.
- Structured log formatter (JSON in prod, human in dev).
- Audit log table and append-only API.
- `tet audit export` with stable JSONL schema.

Pass condition: `:telemetry_test` assertions cover every documented
event; audit log records the documented event categories; export
round-trips through `jq`.

## Phase 13 (v1.x) — Extensions

Per `extensions/15_mcp_and_agents.md`. MCP, multi-agent profiles,
custom slash commands. Optional and additive.

## Phase 14 (v1.x) — Multi-node

Per `upgrades/13_operations_and_telemetry.md` §"Multi-node." Postgres
advisory locks for workflow ownership; `:pg`-backed event bus for
cross-node delivery. Only relevant for `tet_web` deployments.

## What this changes about the milestone script

The first-milestone script in `docs/03` still works unchanged. v0.3
adds an additional acceptance gate: the same script must work
against a build with `MIX_ENV=prod` after a SIGKILL-and-restart in
the middle of `tet edit`'s diff proposal. If that script doesn't
survive a kill, the durable execution acceptance has failed.

```bash
# v0.3 milestone addendum
tet init . --trust
tet doctor
S=$(tet session new . --mode execute)
tet edit "$S" "add a short README note" &
EDIT_PID=$!
sleep 0.5
kill -KILL $EDIT_PID
# restart implied by next command bringing up the runtime fresh
tet approvals "$S"   # the proposed approval should appear
tet patch approve appr_001
```
