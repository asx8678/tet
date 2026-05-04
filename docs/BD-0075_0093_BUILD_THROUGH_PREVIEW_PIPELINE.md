# BD-0075 through BD-0093 — Build through preview pipeline

Owner: `planning-agent-7ca0e2`
Scope: 19 backlog items across 4 new phases (21–24) bridging the BUILD → PREVIEW gap.

The implementation phases (0–20) produced all core modules, contracts, tests,
tools, providers, stores, and release gates. These phases prove the assembled
product actually works end-to-end before any real user touches it. Vibes-based
release confidence is not confidence; it is denial with a deploy button.

---

## Phase 21 — Build Verification 🔨

The most critical immediate step: confirm the entire codebase compiles, tests
pass, and the release assembles cleanly. Nothing after this matters if the
build is broken.

### BD-0075: Format verification

Issue: `tet-db6.75` / `BD-0075: Format verification`
Category: verifying
Phase: 21 / Build verification
Depends on: BD-0074
Status: Open

**Description.** Run `mix format --check-formatted` across the entire umbrella
and fix any formatting drift. The formatter is the cheapest gate and the first
to break when large codegen or patch waves land without a trailing format pass.

**Acceptance criteria.** `mix format --check-formatted` exits 0 with no diff
output from any app in the umbrella.

**Verification command.**

```sh
mix format --check-formatted
```

**Source references.** Root `mix.exs` aliases; `.formatter.exs` if present;
`tools/check_release_acceptance.sh` formatting gate.

---

### BD-0076: Compile clean with warnings-as-errors

Issue: `tet-db6.76` / `BD-0076: Compile clean with warnings-as-errors`
Category: verifying
Phase: 21 / Build verification
Depends on: BD-0075
Status: Open

**Description.** Compile the full umbrella with `--warnings-as-errors` in both
`:test` and `:prod` environments. Catch unused variables, deprecated calls,
unreachable clauses, missing function heads, and dead module references before
they become runtime surprises. Warnings in a codebase this size are not
decoration; they are future bugs auditioning.

**Acceptance criteria.** `MIX_ENV=test mix compile --warnings-as-errors` and
`MIX_ENV=prod mix compile --warnings-as-errors` both exit 0 with zero warnings.

**Verification commands.**

```sh
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=prod mix compile --warnings-as-errors
```

**Source references.** `tools/check_release_acceptance.sh` compile gate;
`mix.exs` umbrella configuration.

---

### BD-0077: Full ExUnit test suite pass

Issue: `tet-db6.77` / `BD-0077: Full ExUnit test suite pass`
Category: verifying
Phase: 21 / Build verification
Depends on: BD-0076
Status: Open

**Description.** Run `mix test` across all umbrella apps and achieve a clean
pass. This covers ~576 test files spanning tet_core, tet_runtime, tet_cli,
tet_store_memory, tet_store_sqlite, and tet_web_phoenix. Failures must be
triaged as either genuine regressions (fix) or stale test expectations from
recent migrations (update). No test should be deleted to make the suite pass
unless the tested behavior was intentionally removed.

**Acceptance criteria.** `MIX_ENV=test mix test` exits 0. Zero failures, zero
errors. Pending/skipped tests are acceptable if annotated with a reason and
target BD.

**Verification command.**

```sh
mix test
```

**Source references.** All `test/` directories under `apps/`;
`apps/tet_core/test/`, `apps/tet_runtime/test/`, `apps/tet_cli/test/`,
`apps/tet_store_memory/test/`, `apps/tet_store_sqlite/test/`,
`apps/tet_web_phoenix/test/`.

**Risk.** This is likely the biggest single task. The SQLite migration from
JSONL may have introduced contract mismatches, and cross-app integration
points may have drifted during parallel feature development. Mitigation:
triage failures by app, fix store contract issues first (they cascade), then
runtime, then CLI.

---

### BD-0078: Standalone boundary check

Issue: `tet-db6.78` / `BD-0078: Standalone boundary check`
Category: verifying
Phase: 21 / Build verification
Depends on: BD-0077
Status: Open

**Description.** Run the combined `mix standalone.check` alias which executes:
format verification, web facade contract check (`tools/check_web_facade_contract.sh`),
security compliance tests, the full test suite, and release dependency closure
check (`tools/check_release_closure.sh`). This is the single-command proof
that the standalone boundary holds.

**Acceptance criteria.** `mix standalone.check` exits 0. All sub-gates pass.

**Verification command.**

```sh
mix standalone.check
```

**Source references.** Root `mix.exs` `standalone.check` alias;
`tools/check_web_facade_contract.sh`; `tools/check_release_closure.sh`;
`docs/adr/0001-standalone-cli-boundary.md`; `docs/adr/0002-phoenix-optional-adapter.md`.

---

### BD-0079: Release assembly

Issue: `tet-db6.79` / `BD-0079: Release assembly`
Category: acting
Phase: 21 / Build verification
Depends on: BD-0078
Status: Open

**Description.** Build the production standalone release with
`MIX_ENV=prod mix release tet_standalone --overwrite`. The release must
assemble without errors, include all four standalone applications
(tet_core, tet_store_sqlite, tet_runtime, tet_cli), exclude all web
applications, and pass the `Tet.Release.assert_standalone_release!/1`
step defined in `mix.exs`.

**Acceptance criteria.** Release artifact exists at
`_build/prod/rel/tet_standalone/` with a working `bin/tet` wrapper.
The release closure contains no Phoenix, LiveView, Plug, Cowboy, or Bandit
applications.

**Verification commands.**

```sh
MIX_ENV=prod mix release tet_standalone --overwrite
tools/check_release_closure.sh --no-build
```

**Source references.** Root `mix.exs` release configuration;
`apps/tet_cli/lib/tet/cli/release.ex`; `tools/check_release_closure.sh`;
`docs/adr/0001-standalone-cli-boundary.md`.

---

### BD-0080: Full release acceptance pipeline

Issue: `tet-db6.80` / `BD-0080: Full release acceptance pipeline`
Category: verifying
Phase: 21 / Build verification
Depends on: BD-0079
Status: Open

**Description.** Run the BD-0074 release acceptance pipeline via
`mix release.acceptance` / `tools/check_release_acceptance.sh`. This
is the complete pre-release gate: source anchor inventory, formatting,
compile warnings, full test suite, provider path, store path, recovery
path, security/boundary checks, standalone release build, first-mile
system smoke, and web removability. Passing this gate means the build
is release-candidate quality.

**Acceptance criteria.** `mix release.acceptance` exits 0. All gates
in the BD-0074 gate map pass. First-mile smoke completes offline with
mock provider.

**Verification command.**

```sh
mix release.acceptance
```

**Source references.** `docs/BD-0074_FINAL_RELEASE_ACCEPTANCE_PIPELINE.md`;
`tools/check_release_acceptance.sh`; `tools/smoke_first_mile.sh`.

**Notes.** This gate subsumes BD-0075 through BD-0079. If BD-0080 passes,
the earlier gates are implicitly satisfied. However, the earlier BDs exist
for incremental triage: when acceptance fails, work backward through the
chain to find the first broken link.

---

## Phase 22 — Smoke Testing 🔥

Once the build assembles, run real end-to-end paths through the release
binary. These are not unit tests; they are the product behaving as a user
would use it.

### BD-0081: Mock provider end-to-end session lifecycle

Issue: `tet-db6.81` / `BD-0081: Mock provider end-to-end session lifecycle`
Category: verifying
Phase: 22 / Smoke testing
Depends on: BD-0080
Status: Open

**Description.** Using the assembled release binary and `TET_PROVIDER=mock`,
exercise the full session lifecycle: create a session, send a prompt, verify
streamed output, send a second prompt to the same session, list sessions,
show the session with all messages, view the event timeline, and verify
persistence in the SQLite store. This is the "first five minutes" user
experience.

**Acceptance criteria.**
- `tet ask --session smoke "first"` streams `mock: first` and persists.
- `tet ask --session smoke "second"` streams `mock: second` and appends.
- `tet sessions` lists `smoke` with message_count=4.
- `tet session show smoke` displays all 4 messages in order.
- `tet events --session smoke` shows persisted runtime events.
- SQLite database at the configured path contains the expected rows.

**Verification commands.**

```sh
STORE=$(mktemp -d /tmp/tet-smoke.XXXXXX)
TET_PROVIDER=mock TET_STORE_PATH="$STORE/.tet/messages.jsonl" \
  _build/prod/rel/tet_standalone/bin/tet ask --session smoke "first"
TET_PROVIDER=mock TET_STORE_PATH="$STORE/.tet/messages.jsonl" \
  _build/prod/rel/tet_standalone/bin/tet ask --session smoke "second"
TET_STORE_PATH="$STORE/.tet/messages.jsonl" \
  _build/prod/rel/tet_standalone/bin/tet sessions
TET_STORE_PATH="$STORE/.tet/messages.jsonl" \
  _build/prod/rel/tet_standalone/bin/tet session show smoke
TET_STORE_PATH="$STORE/.tet/messages.jsonl" \
  _build/prod/rel/tet_standalone/bin/tet events --session smoke
```

**Source references.** `README.md` smoke test section; `tools/smoke_first_mile.sh`;
`docs/README.md` session list/show/resume documentation.

---

### BD-0082: Real provider streaming verification

Issue: `tet-db6.82` / `BD-0082: Real provider streaming verification`
Category: verifying
Phase: 22 / Smoke testing
Depends on: BD-0081
Status: Open

**Description.** Verify streaming chat against at least one real provider
(OpenAI-compatible endpoint or Anthropic). This catches real-world SSE
parsing, auth header handling, model name resolution, `data: [DONE]`
detection, error classification, and timeout behavior that mock providers
cannot exercise. Must NOT run in CI or automated pipelines; this is
an operator-driven manual verification with real API keys.

**Acceptance criteria.**
- OpenAI-compatible: `TET_PROVIDER=openai_compatible` with valid API key
  streams a complete response and persists both messages.
- Anthropic: `TET_PROVIDER=anthropic` with valid API key streams a
  complete response and persists both messages.
- Incomplete streams (network drop, timeout) produce a clear error, not
  a partial persisted assistant message.
- Session resume after real provider turns works correctly.

**Verification commands.**

```sh
# OpenAI-compatible
TET_PROVIDER=openai_compatible \
TET_OPENAI_API_KEY="$OPENAI_API_KEY" \
TET_OPENAI_MODEL="gpt-4o-mini" \
  _build/prod/rel/tet_standalone/bin/tet ask "say hi in five words"

# Anthropic
TET_PROVIDER=anthropic \
TET_ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  _build/prod/rel/tet_standalone/bin/tet ask "say hi in five words"
```

**Verification script.** `tools/check_real_provider_streaming.sh` provides
automated manual verification:

```bash
# Verify OpenAI-compatible provider
OPENAI_API_KEY="$OPENAI_API_KEY" tools/check_real_provider_streaming.sh --openai

# Verify Anthropic provider
ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" tools/check_real_provider_streaming.sh --anthropic

# Verify both providers
OPENAI_API_KEY="$OPENAI_API_KEY" ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  tools/check_real_provider_streaming.sh --all
```

**Source references.** `apps/tet_runtime/lib/tet/runtime/provider/anthropic.ex`;
`apps/tet_runtime/lib/tet/runtime/provider/openai_compatible.ex`;
`tools/check_real_provider_streaming.sh`;
`docs/README.md` provider configuration section.

**Risk.** Provider APIs may change response formats. Mitigation: pin known
model versions, test against stable endpoints, and verify SSE chunk
parsing handles edge cases.

---

### BD-0083: Doctor diagnostics under varied configurations

Issue: `tet-db6.83` / `BD-0083: Doctor diagnostics under varied configurations`
Category: verifying
Phase: 22 / Smoke testing
Depends on: BD-0081
Status: Open

**Description.** Run `tet doctor` under multiple configurations and verify
it produces accurate, helpful diagnostics:
- Default mock provider: all checks pass.
- Missing API key for OpenAI-compatible: provider check fails with actionable
  message naming `TET_OPENAI_API_KEY`.
- Missing API key for Anthropic: provider check fails with actionable message.
- Invalid store path: store check fails with clear path/permission message.
- Valid full configuration: all checks pass including release boundary.

**Acceptance criteria.** Doctor output matches the documented format from
`docs/README.md`. Exit code is 0 for healthy, non-zero for errors. Error
messages name the specific env var or path that needs fixing.

**Verification commands.**

```sh
# Healthy
TET_PROVIDER=mock _build/prod/rel/tet_standalone/bin/tet doctor

# Missing key
TET_PROVIDER=openai_compatible TET_OPENAI_API_KEY= \
  _build/prod/rel/tet_standalone/bin/tet doctor

# Bad store path
TET_STORE_PATH=/nonexistent/path \
  _build/prod/rel/tet_standalone/bin/tet doctor
```

**Source references.** `apps/tet_runtime/lib/tet/runtime/doctor.ex`;
`docs/README.md` doctor diagnostics section.

---

### BD-0084: SQLite durability and session resume integrity

Issue: `tet-db6.84` / `BD-0084: SQLite durability and session resume integrity`
Category: verifying
Phase: 22 / Smoke testing
Depends on: BD-0081
Status: Open

**Description.** Verify that the SQLite store (now the default, replacing JSONL)
correctly persists and retrieves all entity types across process restarts:
- Messages survive session quit and resume.
- Autosave checkpoints are written and restorable.
- Runtime events are durably stored with correct sequence numbers.
- Session summaries are derived correctly from stored messages.
- WAL mode is active and PRAGMA settings match expectations.
- Concurrent read access does not block or corrupt.

**Acceptance criteria.**
- Create session, send messages, kill process, restart, resume — all
  messages present and ordered.
- `tet doctor` reports SQLite store health as ok with correct PRAGMA values.
- Prompt Lab history entries survive restart.
- Autosave checkpoint is restorable after restart.

**Verification approach.** Use the release binary with a temporary store path.
Send messages, terminate the BEAM, restart, and verify data integrity through
CLI commands and direct SQLite inspection.

**Source references.** `apps/tet_store_sqlite/lib/tet/store/sqlite.ex`;
`apps/tet_store_sqlite/lib/tet/store/sqlite/connection.ex`;
`apps/tet_store_sqlite/test/crash_recovery_test.exs`;
`docs/adr/0009-sqlite-adapter-library-choice.md`.

---

### BD-0085: Web removability regression

Issue: `tet-db6.85` / `BD-0085: Web removability regression`
Category: verifying
Phase: 22 / Smoke testing
Depends on: BD-0080
Status: Open

**Description.** Run the full web removability gate to prove that
`tet_web_phoenix` remains strictly optional. The gate copies the repo to a
sandbox, removes optional web apps, compiles, tests, builds standalone, and
verifies the facade guard catches a synthetic Phoenix leak. This is the
definitive proof that no web dependency has crept into the standalone path
during the implementation of phases 0–20.

**Acceptance criteria.** `tools/check_web_removability.sh` exits 0. The
sandbox standalone release builds and smokes without `tet_web_phoenix`.
The negative smoke (synthetic Phoenix leak) is detected and rejected.

**Verification command.**

```sh
tools/check_web_removability.sh
```

**Source references.** `docs/BD-0009_WEB_REMOVABILITY_GATE.md`;
`tools/check_web_removability.sh`; `docs/adr/0002-phoenix-optional-adapter.md`.

---

## Phase 23 — Integration Gap Closure 🔗

Items flagged during codebase analysis that need verification or completion
before the product is integration-complete.

### BD-0086: Hook system integration wiring

Issue: `tet-db6.86` / `BD-0086: Hook system integration wiring`
Category: acting
Phase: 23 / Integration gap closure
Depends on: BD-0077
Status: Open

**Description.** Test files reference "Hook system stubbed until BD-0024
merges" (found in `apps/tet_core/test/tet/plan_mode/invariants_gate_test.exs`).
BD-0024 (HookManager and ordering) has implementation code in
`apps/tet_core/lib/tet/hook_manager.ex` and
`apps/tet_core/lib/tet/hook_manager/hook.ex`, but the integration stubs in
plan mode gate tests suggest the wiring between plan mode gates and the hook
system may be incomplete.

**Tasks.**
1. Audit all "BD-0024" and "hook stub" references in test files.
2. Verify `Tet.HookManager` is called from `Tet.PlanMode.Gate` where expected.
3. Replace stubs with real hook integration or document why the stub is
   intentionally permanent (e.g., hook system is optional and tests validate
   gate logic independently).
4. Ensure the five cross-phase invariants are tested with hooks active.

**Acceptance criteria.** All "stubbed until BD-0024" comments are resolved:
either replaced with real hook calls or annotated as intentionally decoupled
with a rationale. Hook ordering tests in `apps/tet_core/test/tet/hook_manager_test.exs`
pass and cover the plan mode integration path.

**Verification command.**

```sh
mix test apps/tet_core/test/tet/plan_mode/ apps/tet_core/test/tet/hook_manager_test.exs
```

**Source references.** `apps/tet_core/lib/tet/hook_manager.ex`;
`apps/tet_core/lib/tet/plan_mode/gate.ex`;
`apps/tet_core/test/tet/plan_mode/invariants_gate_test.exs`;
`docs/BD-0025_PLAN_MODE_GATES.md`.

---

### BD-0087: Anthropic provider real-world streaming maturity

Issue: `tet-db6.87` / `BD-0087: Anthropic provider real-world streaming maturity`
Category: acting
Phase: 23 / Integration gap closure
Depends on: BD-0082
Status: Open

**Description.** The Anthropic provider adapter
(`apps/tet_runtime/lib/tet/runtime/provider/anthropic.ex`, ~16KB) needs
real-world streaming verification. Anthropic's Messages API uses a different
SSE format than OpenAI (`event:` prefixed types, `message_start`,
`content_block_delta`, `message_stop` events). Verify:
1. Normal streaming works end-to-end.
2. Tool-call responses parse correctly (if supported at this phase).
3. Rate limit errors (`429`) produce retryable error events.
4. Timeout and network errors produce clear non-retryable events.
5. Incomplete streams (missing `message_stop`) are not persisted.
6. Cache control headers/hints are handled if Anthropic prompt caching is used.

**Acceptance criteria.** A real Anthropic API call streams, persists, and
resumes correctly. The provider adapter test suite
(`apps/tet_runtime/test/tet/provider_anthropic_test.exs`) covers all
SSE event types with fixture replay.

**Verification commands.**

```sh
# Unit tests with fixtures
mix test apps/tet_runtime/test/tet/provider_anthropic_test.exs

# Manual real-provider smoke (operator-driven, not CI)
TET_PROVIDER=anthropic TET_ANTHROPIC_API_KEY="$KEY" \
  _build/prod/rel/tet_standalone/bin/tet ask "hello"
```

**Source references.** `apps/tet_runtime/lib/tet/runtime/provider/anthropic.ex`;
`apps/tet_runtime/test/tet/provider_anthropic_test.exs`;
`apps/tet_runtime/lib/tet/runtime/provider/stream_events.ex`.

---

### BD-0088: Legacy JSONL importer verification

Issue: `tet-db6.88` / `BD-0088: Legacy JSONL importer verification`
Category: verifying
Phase: 23 / Integration gap closure
Depends on: BD-0084
Status: Open

**Description.** The SQLite store includes a JSONL importer
(`apps/tet_store_sqlite/lib/tet/store/sqlite/importer.ex`, ~12.6KB) for
migrating existing `.tet/` JSONL data into the new SQLite database. This
importer needs verification against real-world JSONL data shapes:
1. Messages with all metadata fields import correctly.
2. Sessions are derived and stored as first-class rows.
3. Runtime events import with correct sequence numbers.
4. Autosave checkpoints import with all nested data.
5. Prompt Lab history entries import correctly.
6. Import is idempotent: running twice does not duplicate data.
7. Corrupt or malformed JSONL lines are skipped with error logging,
   not crash the importer.
8. The `legacy_jsonl_imports` tracking table records what was imported.

**Acceptance criteria.** Importer tests pass with fixture JSONL data covering
all entity types. Idempotency is verified (double-import produces same row
count). Malformed lines produce warnings, not crashes.

**Verification commands.**

```sh
mix test apps/tet_store_sqlite/test/ --include importer
# Or run all SQLite tests:
mix test apps/tet_store_sqlite/
```

**Source references.** `apps/tet_store_sqlite/lib/tet/store/sqlite/importer.ex`;
`apps/tet_store_sqlite/lib/tet/store/sqlite/schema/legacy_jsonl_import.ex`;
`apps/tet_store_sqlite/DESIGN_SQLITE_MIGRATION.md`.

---

### BD-0089: Migration execute flow completion

Issue: `tet-db6.89` / `BD-0089: Migration execute flow completion`
Category: acting
Phase: 23 / Integration gap closure
Depends on: BD-0077
Status: Open

**Description.** `Tet.Migration` (`apps/tet_core/lib/tet/migration.ex`)
contains stubs for the actual file I/O execute flow (noted in grep as
"Stubs for execute flow — actual file I/O"). The migration module defines
the analysis, safety check, and reporting pipeline, but the execution
path that actually performs config file transformations may be incomplete.

**Tasks.**
1. Audit `Tet.Migration` for all stub/placeholder functions.
2. Determine which stubs need implementation vs. which are intentionally
   deferred (migration execution may be a future phase).
3. If stubs are intentionally deferred: document the deferral with a clear
   rationale and ensure the module returns informative errors when execute
   is called on a stub path.
4. If stubs need implementation: implement the file I/O operations with
   dry-run-first safety, backup creation, and rollback support.

**Acceptance criteria.** All stubs are either implemented with tests or
explicitly documented as deferred with helpful error messages. The migration
test suite (`apps/tet_core/test/tet/migration/migration_test.exs`) passes
and covers the stub boundaries.

**Verification command.**

```sh
mix test apps/tet_core/test/tet/migration/
```

**Source references.** `apps/tet_core/lib/tet/migration.ex`;
`apps/tet_core/lib/tet/migration/config_mapper.ex`;
`apps/tet_core/lib/tet/migration/safety_check.ex`;
`apps/tet_core/test/tet/migration/migration_test.exs`.

---

## Phase 24 — Pre-Release Polish ✨

Final quality gates before the product moves from BUILD to PREVIEW status.

### BD-0090: Security compliance suite execution

Issue: `tet-db6.90` / `BD-0090: Security compliance suite execution`
Category: verifying
Phase: 24 / Pre-release polish
Depends on: BD-0078
Status: Open

**Description.** The security infrastructure is built: compliance suite
(`apps/tet_core/lib/tet/security/compliance_suite.ex` with checks for
data protection, file system, and trust boundary), path fuzzer, secret
fuzzer, security policy evaluator, and three-layer redactor. Now run
them systematically and fix any findings:
1. `mix security.compliance` — run the compliance check suite.
2. Review path fuzzer results for traversal escapes.
3. Review secret fuzzer results for leaks in provider/log/display paths.
4. Verify redactor layers (inbound, outbound, display) catch known patterns.
5. Verify `Tet.Secrets.PatternRegistry` patterns are current.

**Acceptance criteria.** `mix security.compliance` exits 0. Path fuzzer
finds no escapes. Secret fuzzer finds no leaks in the standard pipeline.
Redactor tests pass across all three layers.

**Verification commands.**

```sh
mix security.compliance
mix test apps/tet_core/test/tet/security/
mix test apps/tet_core/test/tet/redactor/
mix test apps/tet_core/test/tet/secrets/
```

**Source references.** `apps/tet_core/lib/tet/security/compliance_suite.ex`;
`apps/tet_core/lib/tet/security/path_fuzzer.ex`;
`apps/tet_core/lib/tet/security/secret_fuzzer.ex`;
`apps/tet_core/lib/tet/redactor/`;
`apps/tet_core/lib/tet/secrets/`.

---

### BD-0091: Documentation topic accuracy and completeness

Issue: `tet-db6.91` / `BD-0091: Documentation topic accuracy and completeness`
Category: documenting
Phase: 24 / Pre-release polish
Depends on: BD-0081
Status: Open

**Description.** BD-0073 added a topic-based documentation system with 10
topics accessible via `tet help`. Verify each topic is accurate against the
current implementation state:
1. CLI usage — commands match actual CLI surface.
2. Configuration — env vars and config options match current code.
3. Profiles — profile names and capabilities match registry.
4. Tools — tool catalog matches `Tet.Tool.read_only_contracts/0` and
   current runtime tool implementations.
5. MCP — MCP commands and lifecycle match implementation.
6. Remote operations — remote commands and protocol match implementation.
7. Repair/self-healing — repair workflow matches implementation.
8. Security policy — policy description matches evaluator.
9. Migration — migration guidance matches current state.
10. Release management — release commands and gates match current scripts.

**Acceptance criteria.** Every "current" command listed in documentation
topics exists and works. Every "future/planned" command is clearly marked.
No documentation topic references modules or commands that do not exist.

**Verification approach.** Cross-reference `tet help` output with actual CLI
dispatch in `apps/tet_cli/lib/tet/cli.ex`. Spot-check each documented command
against the release binary.

**Source references.** `apps/tet_core/lib/tet/docs.ex`;
`apps/tet_core/lib/tet/docs/topic.ex`;
`apps/tet_cli/lib/tet/cli/help_formatter.ex`;
`docs/BD-0073_DOCUMENTATION_AND_CLI_HELP.md`.

---

### BD-0092: Release binary size and startup performance budget

Issue: `tet-db6.92` / `BD-0092: Release binary size and startup performance budget`
Category: verifying
Phase: 24 / Pre-release polish
Depends on: BD-0079
Status: Open

**Description.** Measure and establish baseline budgets for:
1. **Release size**: Total size of `_build/prod/rel/tet_standalone/`.
   Establish a baseline and flag if it exceeds reasonable bounds for a
   CLI tool (target: under 50MB compressed, document actual).
2. **Startup time**: Time from `tet doctor` invocation to first output.
   Target: under 2 seconds on modern hardware.
3. **First-ask latency**: Time from `tet ask` invocation (mock provider)
   to first streamed chunk. Target: under 1 second.
4. **Dependency audit**: Verify no unnecessary dependencies bloat the
   release (e.g., dev-only deps leaking into prod).

**Acceptance criteria.** Baseline measurements are documented. No obvious
bloat is found. If targets are exceeded, specific causes are identified
and either fixed or documented with justification.

**Verification commands.**

```sh
# Release size
du -sh _build/prod/rel/tet_standalone/
du -sh _build/prod/rel/tet_standalone/ | tar -czf /tmp/tet-size-check.tar.gz \
  -C _build/prod/rel tet_standalone && ls -lh /tmp/tet-size-check.tar.gz

# Startup time
time _build/prod/rel/tet_standalone/bin/tet doctor

# First-ask latency
time TET_PROVIDER=mock _build/prod/rel/tet_standalone/bin/tet ask "hello"

# Dependency list
_build/prod/rel/tet_standalone/bin/tet_standalone eval \
  ':application.which_applications() |> Enum.map(&elem(&1, 0)) |> Enum.sort() |> IO.inspect()'
```

**Source references.** Root `mix.exs` release configuration;
`apps/tet_cli/lib/tet/cli/release.ex`.

---

### BD-0093: User-facing error message quality audit

Issue: `tet-db6.93` / `BD-0093: User-facing error message quality audit`
Category: verifying
Phase: 24 / Pre-release polish
Depends on: BD-0081
Status: Open

**Description.** Systematically trigger every user-facing error path and
verify the output is helpful, not a raw stack trace or cryptic atom:
1. **Missing provider config**: Clear message naming the env var needed.
2. **Invalid session ID**: Helpful "session not found" with suggestion.
3. **Store permission errors**: Clear path and permission message.
4. **Network errors during streaming**: Timeout/connection message, not
   an Erlang exception dump.
5. **Invalid command/flag**: Usage hint with closest valid command.
6. **Provider API errors**: HTTP status + provider error message, not
   raw response body.
7. **SQLite errors**: Clear database path and suggested fix.
8. **Profile not found**: List available profiles in error message.
9. **Tool contract violations**: Explain what went wrong and what's expected.

**Acceptance criteria.** Every triggered error path produces a message that
a user unfamiliar with Elixir/OTP internals can understand and act on. No
raw exception structs, no `%Protocol.UndefinedError{}`, no `** (EXIT)` in
normal user-facing output.

**Verification approach.** Manual fault injection through the release binary.
Document each error scenario, trigger it, and screenshot/capture the output.

**Source references.** `apps/tet_cli/lib/tet/cli.ex`;
`apps/tet_cli/lib/tet/cli/render.ex`;
`apps/tet_runtime/lib/tet/runtime/provider/error.ex`.

---

## Dependency graph

```
Phase 21 — Build Verification
BD-0075 (format) → BD-0076 (compile) → BD-0077 (test) → BD-0078 (standalone.check) → BD-0079 (release) → BD-0080 (acceptance)

Phase 22 — Smoke Testing (all depend on BD-0080)
BD-0081 (mock smoke) → BD-0082 (real provider)
BD-0081 (mock smoke) → BD-0083 (doctor)
BD-0081 (mock smoke) → BD-0084 (SQLite durability)
BD-0080 (acceptance) → BD-0085 (web removability)

Phase 23 — Integration Gaps
BD-0077 (test) → BD-0086 (hook wiring)
BD-0082 (real provider) → BD-0087 (Anthropic maturity)
BD-0084 (SQLite durability) → BD-0088 (JSONL importer)
BD-0077 (test) → BD-0089 (migration stubs)

Phase 24 — Pre-Release Polish
BD-0078 (standalone.check) → BD-0090 (security compliance)
BD-0081 (mock smoke) → BD-0091 (documentation accuracy)
BD-0079 (release) → BD-0092 (size/startup budget)
BD-0081 (mock smoke) → BD-0093 (error messages)
```

## Agent coordination recommendations

| BD range | Recommended agent | Rationale |
|----------|------------------|-----------|
| BD-0075–BD-0080 | `elixir-reviewer` + `agent-platform-architect` | Build verification is architecture-sensitive |
| BD-0081–BD-0085 | `cli-engineer` + `sqlite-embedded-specialist` | Smoke testing exercises CLI and store boundaries |
| BD-0086 | `otp-runtime-architect` | Hook/gate wiring is OTP design |
| BD-0087 | `llm-provider-specialist` | Anthropic SSE format is provider-specific |
| BD-0088 | `sqlite-embedded-specialist` | JSONL → SQLite is store domain |
| BD-0089 | `elixir-programmer` | Migration stubs are general Elixir |
| BD-0090 | `security-auditor` + `secrets-redaction-auditor` | Security is their domain |
| BD-0091 | `cli-engineer` + `adr-writer` | Docs accuracy is CLI + architecture |
| BD-0092 | `agent-platform-architect` | Release budget is architecture |
| BD-0093 | `cli-engineer` | Error UX is CLI domain |

## Phase summary

| Phase | BDs | Category | Description | Estimated effort |
|-------|-----|----------|-------------|-----------------|
| 21 | BD-0075–BD-0080 | Build Verification | Compile, test, release, acceptance | Medium-Large |
| 22 | BD-0081–BD-0085 | Smoke Testing | End-to-end product paths | Medium |
| 23 | BD-0086–BD-0089 | Integration Gaps | Stubs, wiring, import verification | Medium |
| 24 | BD-0090–BD-0093 | Pre-Release Polish | Security, docs, size, UX | Medium |

Total: 19 BDs across 4 phases. Completing all 19 moves the project from
BUILD → PREVIEW status.
