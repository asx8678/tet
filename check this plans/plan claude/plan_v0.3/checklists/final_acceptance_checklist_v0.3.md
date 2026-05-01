# Final Acceptance Checklist — v0.3

> Split by scope bucket per `upgrades/17_phasing_and_scope.md`. v1
> must-haves are blocking for release. v1 nice-to-haves are blocking
> if marked "ship-with-v1" by the team and merely planned otherwise.
> v1.x items are tracked here for completeness; they are not
> blocking for v1 release.

## v1 — must-have

### Boundary, structure, guards (carries from v0.1)

- [ ] Umbrella structure: `tet_core`, `tet_runtime`, `tet_cli`,
      `tet_store_memory`, `tet_store_sqlite`, optional
      `tet_web_phoenix`, optional `tet_store_postgres`.
- [ ] `Tet` is the public facade in `apps/tet_runtime/lib/tet.ex`.
      No CLI / Phoenix code calls anything else in the umbrella.
- [ ] `tet_core` has zero `:phoenix`, `:phoenix_live_view`, `:plug`,
      `:cowboy`, `:bandit`, `:ecto_sql` references.
- [ ] `tet_runtime` has zero `:phoenix*`, `:plug`, `:cowboy`, `:bandit`
      references.
- [ ] `tet_cli` and `tet_web_phoenix` only call `Tet.*` functions
      (facade-only guard).
- [ ] Five gates pass on every push: dependency-closure, `mix xref`,
      source grep, runtime smoke, release-closure check.
- [ ] Removability test: building with `tet_web_phoenix` excluded
      still produces a working `tet_standalone` release; tests pass.
- [ ] **Atom-handling guard**: no `String.to_atom` or
      `String.to_existing_atom` outside `Tet.Codec` and a small
      allowlist of known-safe call sites.
- [ ] **Credential-env guard**: no `System.get_env` for any string
      ending in `_API_KEY`, `_TOKEN`, `_SECRET` outside
      `Tet.Secrets`.
- [ ] **No-`SessionWorker` guard**: source grep confirms no module
      named `SessionWorker` exists.
- [ ] Every guard ships with a deliberate failing-fixture under
      `tools/test_guards_fail/` so removing the guard fails CI.

### Core contracts

- [ ] `Tet.Codec` with allowlists for every atom-typed status field,
      explicit encoder/decoder per type (no broken macros).
- [ ] `Tet.Codec` round-trip property test passes for every
      allowlisted atom.
- [ ] `Tet.Workflow` and `Tet.WorkflowStep` schemas in core.
- [ ] Step name regex `^[a-z_]+(:[a-z0-9_]+)*$` enforced at insert;
      property-tested.
- [ ] `Tet.Workflow.IdempotencyKey.build/3` is deterministic on the
      same scoped input; covered by tests.
- [ ] Idempotency input scope per step type matches the table in
      `upgrades/12_durable_execution.md`.
- [ ] `Tet.Workspace.Trust` struct replaces binary trust state;
      defaults preserve backward-compat semantics.
- [ ] `Tet.Patch.Change` records cover create / delete / modify /
      rename / mode_change uniformly.
- [ ] `Tet.LLM.Provider` behaviour with normalized streaming events
      and explicit `request_id` for idempotency.
- [ ] `Tet.Secrets` behaviour with env adapter as v1 default.
- [ ] `Tet.EventBus` distinguishes workflow events
      (`Tet.Codec.workflow_event_types/0`) from domain events
      (`Tet.Codec.domain_event_types/0`).

### Runtime

- [ ] `Tet.Application` boots with the v0.3 supervision tree exactly
      (`addenda/01_architecture_addendum.md`).
- [ ] `Tet.Runtime.WorkflowSupervisor` supervises one
      `WorkflowExecutor` per active workflow.
- [ ] `Tet.Runtime.WorkflowRecovery` runs once at boot and handles
      pending workflows per the doc-12 decision tree.
- [ ] `Tet.cancel/2` on the facade; `tet cancel SESSION_ID` and
      `--force` variants.
- [ ] Cancellation aborts in-flight provider stream within 1s under
      default settings.
- [ ] `Tet.Runtime.SessionSupervisor` is dispatch-only; holds no
      per-session state.

### Storage

- [ ] `Tet.Store` behaviour extended with `start_step`,
      `commit_step`, `fail_step`, `cancel_step`, `claim_workflow`,
      `list_pending_workflows`, `list_steps`, `schema_version`.
- [ ] Memory and SQLite implementations of all callbacks pass shared
      contract tests.
- [ ] Unique constraint on `(workflow_id, idempotency_key)` rejects
      duplicate commits.
- [ ] Partial unique index ensures one paused-for-approval workflow
      per session.
- [ ] `claim_workflow` returns `{:ok, :claimed}` unconditionally on
      single-node.
- [ ] `tet doctor` reports schema version; on mismatch, refuses to
      start with a clear error and suggests `tet migrate`.
- [ ] `tet migrate` is forward-only and emits a `workspace.migrated`
      audit entry.

### Provider

- [ ] Two adapters ship: `Tet.LLM.Providers.Anthropic` and
      `Tet.LLM.Providers.OpenAICompatible`.
- [ ] Tool-call bidirectional map for both adapters covered by
      property tests.
- [ ] Streaming events are recorded in the journal before being
      acted on.
- [ ] Retry/timeout/stream-stall behaviour matches doc 11; stall
      retry honors the 250ms floor.
- [ ] Bundled `priv/models.json` model registry loads on first call.
- [ ] User overrides at `~/.config/tet/models.json` win; workspace
      overrides at `<workspace>/.tet/models.json` win further.
- [ ] `tet model list` and `tet model show` work without network
      access.
- [ ] Models without tool-call support are rejected from explore /
      execute sessions with `:provider_lacks_tool_calls`.

### Patch and approval

- [ ] Snapshot phase writes `<approval_id>/manifest.json` atomically
      (`tmp` + `rename`).
- [ ] `git apply --check` runs as the dry run before any write.
- [ ] Default applier is plain `git apply` (working tree); `--index`
      is opt-in via `[execute].apply_to_index`.
- [ ] Per-change-type rollback covers create / delete / modify /
      rename / mode_change.
- [ ] Rollback is idempotent (running twice is safe).
- [ ] `Tet.Patch.validate/2` rejects diffs touching redacted
      regions with `:patch_touches_redacted_region`.
- [ ] Approval rows survive runtime restart; resume after approval
      works correctly.

### Recovery

- [ ] L5 recovery integration tests cover every step boundary in
      doc 12 (`upgrades/18_test_strategy.md`).
- [ ] Kill mid-`patch_apply` after snapshot, before `git apply`:
      restart triggers no-op rollback, workflow ends `:failed` with
      `:patch_torn_recovered`.
- [ ] Kill mid-`patch_apply` during `git apply`: restart triggers
      rollback that restores files; workspace hash matches
      pre-apply.
- [ ] Kill mid-`provider_call:attempt:1`: restart starts
      `:attempt:2` with the same `compose_prompt_output_id`-derived
      key.
- [ ] Cancel-vs-crash race handled correctly (cancelled workflows
      are not re-executed by recovery).

### Secrets and redaction

- [ ] `Tet.Secrets.Env` reads provider keys from named env vars.
- [ ] `tet config show` never prints credential values, including in
      `--json`.
- [ ] Layer 1 redaction runs in the prompt composer's tool-output
      path before adding to conversation history.
- [ ] Layer 2 redaction runs before audit log and structured log
      writes.
- [ ] Layer 3 redaction runs on terminal display.
- [ ] Layer 1 redaction is idempotent on the same secret across
      multiple tool calls within one workflow.
- [ ] Entropy backstop detects high-entropy tokens of length ≥ 24
      with configurable threshold.
- [ ] Verifier env is allowlist-built; tests assert no `*_API_KEY`
      ever reaches the verifier subprocess.
- [ ] `provider_payload` artifacts post-redaction are scanned for
      secret patterns; zero unredacted matches across the test
      corpus.
- [ ] L2 property test: 1000 random files with planted secrets read
      → provider payloads contain zero unredacted matches.

### Per-path trust

- [ ] `tet workspace trust . --allow GLOB --deny GLOB` configures
      per-path allowlists.
- [ ] Path policy returns `:path_denied_by_trust` when deny-globs
      match.
- [ ] Property test: deny-globs always win over allow-globs across
      arbitrary glob/path pairs.

### Telemetry, logs, audit

- [ ] All telemetry events listed in `upgrades/13_operations_and_telemetry.md`
      are emitted at the named points; `:telemetry_test` assertions
      cover each.
- [ ] Default log formatter produces structured JSON in prod, human
      in dev.
- [ ] Audit log records: every blocked tool, trust state change,
      config change, workflow recovery, every provider attempt
      (with redacted payload reference).
- [ ] `tet audit export` produces JSONL with stable schema.
- [ ] No HTTP server is started in `tet_standalone`; release closure
      check passes.

### CLI

- [ ] `--json` is supported on every read command; round-trips
      through `jq`.
- [ ] JSON keys are stable snake_case (covered by a key-stability
      test).
- [ ] Streaming commands emit JSON Lines in `--json` mode.
- [ ] Errors in `--json` mode write to stderr with documented exit
      codes.
- [ ] `tet help`, `tet --version`, `tet --license` work and are
      generated from a single source.
- [ ] `Ctrl-C` once in `tet chat` cancels the in-flight prompt
      without exiting; twice within 1s exits.
- [ ] `tet cancel SESSION_ID` returns within 5s under default
      settings.
- [ ] `NO_COLOR=1` and `--no-color` honored; non-TTY stdout has no
      escape codes.

### Tests (the pyramid)

- [ ] L1 unit tests pass on every push; total < 1s.
- [ ] L2 property + fuzz tests pass on every push (max-runs 100 in
      PR, 1000 nightly).
- [ ] L3 provider conformance + golden tests pass on every push for
      both shipped adapters.
- [ ] L4 store contract tests pass against memory and SQLite on
      every push.
- [ ] L5 crash + recovery integration tests pass nightly and on PRs
      labeled `recovery`.
- [ ] L6 boundary guards (the five gates plus v0.3 additions) pass
      on every push.
- [ ] L7 system smoke + first-milestone CLI script passes on every
      push against a built `tet_standalone` release.
- [ ] **v0.3 milestone addendum**: SIGKILL during `tet edit`
      followed by restart leaves the proposed approval visible and
      approvable.

## v1 — nice-to-have (ship-with-v1 if time permits)

- [ ] Shell completion (`tet completion {bash,zsh,fish}`) with
      completion cache file at `~/.cache/tet/completion-cache.json`,
      refreshed atomically by the runtime on session/approval/agent/
      model changes.
- [ ] First Tab returns within 50ms; dynamic Tab returns within 50ms.
- [ ] Stale or missing cache silently falls back to static-only;
      no live `tet --json` calls per Tab press.
- [ ] `tet truncate SESSION_ID --keep N` flags older messages
      `included_in_prompt: false`; emits `session.truncated`.
- [ ] Streaming progress spinner that hands off to streaming text
      in `tet ask` and `tet edit`.
- [ ] `tet patch approve --watch` streams subsequent events until a
      terminal state.
- [ ] `tet doctor --network` enumerates outbound endpoints.

## v1.x — explicit non-blocking

These are tracked but not part of v1 acceptance.

### Multi-node

- [ ] `Tet.Store.Postgres` adapter implements the workflow journal
      contract.
- [ ] `claim_workflow` uses `pg_try_advisory_xact_lock`; locks
      released on TCP teardown.
- [ ] `Tet.EventBus` `:pg`-backed implementation works across the
      Erlang cluster.
- [ ] On planned shutdown, nodes release claims and emit
      `workflow.released_for_failover`.

### Extensions

- [ ] `Tet.MCP.Transport.Stdio` and `Tet.MCP.Transport.HTTP` pass
      conformance tests against MCP reference servers.
- [ ] All MCP tools default to `:write`; operator allowlist promotes
      specific tools to `:read`.
- [ ] `Tet.Agent.Profile` validator and `Tet.Agent.Registry`.
- [ ] `tet session new --agent <name>` and `/agent <name>` switching.
- [ ] Custom slash commands discovered from documented locations,
      EEx-templated.
- [ ] `AGENT.md` loaded into prompts for all modes (chat included).

### Other v1.x

- [ ] OS keychain adapter (`Tet.Secrets.Keychain`) via
      platform-native shell-out, gated on
      `[secrets].adapter = "keychain"`.
- [ ] Live `models.dev` integration via `tet model refresh`,
      cached with 24h TTL.
- [ ] `tet rpc` JSON-RPC editor protocol over stdio.
- [ ] StatsD-over-UDP telemetry handler.
- [ ] Summarization-based truncation (`--strategy summary`).
- [ ] Round-robin provider key rotation as a wrapper provider.

## Sign-off

This checklist is the gate. A v1 release ships when every "v1 —
must-have" item is checked. A "v1 nice-to-have" item flagged
"ship-with-v1" by the team is also blocking; otherwise it carries to
the next milestone. v1.x items are roadmap, not gates.
