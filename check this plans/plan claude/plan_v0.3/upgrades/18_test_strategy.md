# 18 — Unified Test Strategy

> **v0.3 introduced this doc** because the v0.2 additions sprinkled
> property tests, fuzz tests, contract tests, telemetry assertions,
> conformance tests, golden tests, and recovery integration tests
> across six docs without unifying them. The original `docs/08` had
> a clean five-layer pyramid; this doc extends it to seven layers
> covering everything v0.3 adds.

## The pyramid

```text
┌──────────────────────────────────────────────────────┐  Slow, broad,
│  L7  System smoke + first-milestone CLI script        │  expensive
├──────────────────────────────────────────────────────┤
│  L6  Acceptance / boundary guards (the five gates +   │
│      facade-only + removability)                       │
├──────────────────────────────────────────────────────┤
│  L5  Crash + recovery integration tests                │
├──────────────────────────────────────────────────────┤
│  L4  Runtime / store contract tests                    │
├──────────────────────────────────────────────────────┤
│  L3  Provider conformance + tool-call golden tests     │
├──────────────────────────────────────────────────────┤
│  L2  Property + fuzz tests                             │
├──────────────────────────────────────────────────────┤
│  L1  Pure unit tests (core)                            │  Fast, narrow,
└──────────────────────────────────────────────────────┘  cheap
```

Layers 1, 4, 6, 7 already exist in `docs/08`; layers 2, 3, 5 are
v0.3 additions.

## L1 — Pure unit tests

In `apps/tet_core/test`. No GenServers, no IO, no fixtures touching
disk.

Targets:

- Command/event struct construction and field defaults.
- Mode policy decisions for the matrix in `docs/05`.
- `Tet.Codec` encode/decode allowlists.
- `Tet.Patch.parse/1` on canonical valid diffs.
- `Tet.Workflow.IdempotencyKey.build/3` determinism on the same
  scoped input.
- `Tet.Patch.Approval` state-helper functions.

Tooling: `ExUnit`. Fast (<1s for the whole suite).

## L2 — Property + fuzz tests

In `apps/tet_core/test/property/` and per-app where security-critical.

Targets:

- `Tet.Codec` round-trip across all allowlisted atoms (`encode |>
  decode == input`).
- `Tet.Patch.Approval` reachability: only legal transitions land on
  legal states.
- `Tet.Workflow` replay determinism: replaying journal produces same
  in-memory state regardless of replay order.
- `Tet.Ids` short-id collision: 10_000 generations within a workspace
  are unique.
- Trust-glob matcher: deny always wins over allow for arbitrary glob
  pairs.
- Path resolver: 10_000 random paths mixing `..`, symlinks, NUL
  bytes, percent-encoding, Windows separators on POSIX, long
  components, case variants. Property: every result is either
  `{:ok, p}` with `p` lexically inside `workspace_root` or a typed
  error.
- Unified-diff parser: malformed inputs (truncated headers,
  mismatched hunks, binary preludes, mixed line endings). Property:
  parser never crashes; either parses or returns a typed error.
- Patch apply/rollback round-trip: 100 generated diffs covering all
  five change kinds (create/delete/modify/rename/mode); after
  apply-then-rollback, workspace hash equals pre-apply.
- Tool-call normalization: random `Tet.LLM.ToolCall` lists serialize
  to provider shape and parse back to the same input.
- Redaction: 1000 random files with planted secrets read through
  layer 1; provider payloads contain zero unredacted secret patterns.

Tooling: `stream_data`. `propcheck` is not a v1 dep (extra hex.pm
dependency for marginal benefit; `stream_data` is bundled with
recent Elixir).

## L3 — Provider conformance + golden tests

In `apps/tet_runtime/test/provider/`.

Targets:

- For each shipped adapter (Anthropic, OpenAICompatible), bidirectional
  map property tests (doc 11 §"Round-trip property test").
- Golden output tests: recorded fixture streams from real providers
  replayed through the adapter; assert the normalized event sequence
  matches a checked-in expected-events JSON.
- Tool-args JSON encoding: OpenAI uses string-encoded JSON in
  `tool_calls.function.arguments`; the adapter encodes/decodes
  losslessly across nested objects, unicode, and edge cases.
- Stop-reason mapping: every provider-native stop_reason maps to the
  documented `Tet.LLM.Provider` reason; unknowns map to `:error`.

Tooling: `ExUnit` with fixture replay. Fixtures recorded once, checked
in as JSON. No live network in CI.

## L4 — Runtime / store contract tests

Already in `docs/08`. Extended for v0.3:

Targets:

- Existing: command validation, event ordering, approval state
  transitions, redaction (now layered).
- New: workflow journal contract (`start_step`, `commit_step`,
  `fail_step`, `cancel_step`, `claim_workflow`, `list_pending_workflows`,
  `list_steps`).
- New: unique constraint on `(workflow_id, idempotency_key)` rejects
  duplicate commits.
- New: `claim_workflow` returns `{:ok, :claimed}` on single-node and
  `{:error, :held_by, _}` on contention (using two test repos
  simulating two nodes against the same Postgres for the multi-node
  test slot).

Run the same suite against `Tet.Store.Memory`, `Tet.Store.SQLite`,
and (post-v1) `Tet.Store.Postgres`. Each adapter is a separate test
target; CI runs all three in parallel.

## L5 — Crash + recovery integration tests

In `apps/tet_runtime/test/recovery/`. New layer.

Targets:

- Kill BEAM mid-`compose_prompt`. Restart. Step re-runs (idempotent),
  workflow continues.
- Kill BEAM mid-`provider_call:attempt:1`. Restart. Either
  `:attempt:1` is committed from a journaled response, or `:attempt:2`
  starts. No double-billing.
- Kill BEAM mid-`tool_run:propose_patch` after diff artifact written
  but before approval row created. Restart. Step recovers via
  content-addressed sha lookup.
- Kill BEAM mid-`patch_apply` *after* snapshot manifest written but
  *before* `git apply` runs. Restart. Rollback runs as a no-op;
  workflow ends `:failed` with `:patch_torn_recovered`.
- Kill BEAM mid-`patch_apply` *during* `git apply`. Restart. Rollback
  restores files; workspace hash matches pre-apply.
- Kill BEAM with workflow `:paused_for_approval`. Restart. Workflow
  remains paused. Human approval after restart resumes correctly.
- Cancel-vs-crash: cancel committed, BEAM dies before workflow
  finishes. Restart. Workflow remains `:cancelled`; recovery skips it.

Tooling: `ExUnit` with a test helper that spawns a child release in
a tmpdir, runs to a known journal state, kills it via SIGKILL,
restarts, and asserts post-recovery invariants. Slow per-test but
small fixed set (~10 tests).

## L6 — Boundary guards

Already in `docs/02` and `implementation/dependency_guards.md`. Run
in CI:

- Mix dependency closure (no Phoenix in `tet_standalone`).
- `mix xref graph` — no forbidden compile-connected edges.
- Source grep guard — no forbidden references.
- Runtime smoke — `Tet.Application` boots without endpoint.
- Release closure check — built release has no Phoenix/Plug/Cowboy.
- Facade-only UI guard — CLI/Phoenix only call `Tet.*`.
- Removability test — `tet_web_phoenix` excluded → standalone still
  builds and tests pass.

v0.3 adds:

- Atom-handling guard: no `String.to_atom` or `String.to_existing_atom`
  in store adapters.
- Credential env guard: no `System.get_env` for known credential
  suffixes outside `Tet.Secrets`.

## L7 — System smoke + first milestone

Already in `docs/03`:

```bash
tet init . --trust
tet doctor
S_CHAT=$(tet session new . --mode chat)
tet ask "$S_CHAT" "what does this repo do?"
S_EXPLORE=$(tet session new . --mode explore)
tet explore "$S_EXPLORE" "find the main entrypoint"
S_EXEC=$(tet session new . --mode execute)
tet edit "$S_EXEC" "add a short README note"
tet approvals "$S_EXEC"
tet patch approve appr_001
tet verify "$S_EXEC" mix_test
tet status "$S_EXEC"
```

Runs against the built standalone release. Uses a stub provider
(records canned responses) so CI does not call out to real LLM
endpoints.

## CI matrix

```text
matrix:
  L1:        every push, every adapter
  L2:        every push, with --max-runs 100 in PR, 1000 nightly
  L3:        every push
  L4:        every push, all three store adapters in parallel
  L5:        nightly + PR labeled `recovery`
  L6:        every push (this is the gate)
  L7:        every push, against built tet_standalone release
```

L5 is nightly-default because the kill-and-restart fixture is slow.
PRs that touch `tet_runtime/lib/tet/runtime/` or any patch/journal
code carry the `recovery` label automatically and run L5.

## What is NOT a layer

- **Manual UAT.** Useful, but not part of the pyramid.
- **Load tests.** Out of v1 scope; sessions are local to one user.
- **External integration tests against real LLM providers.** A small
  smoke set runs weekly against a quota-bounded API key, but is not
  blocking.

## Acceptance

- [ ] L1–L7 are wired into CI per the matrix.
- [ ] Every test added in v0.3 docs maps to one of L1–L7.
- [ ] Total CI time on a clean PR (excluding L5 and weekly external
      smokes) is under 10 minutes on the standard runner.
- [ ] L5 recovery tests run nightly and gate the next morning's
      release branch.
