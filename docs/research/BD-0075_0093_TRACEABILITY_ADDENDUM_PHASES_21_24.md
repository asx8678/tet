# BD-0075–BD-0093 Traceability addendum: Phases 21–24

Owner: `planning-agent-7ca0e2`
Extends: `docs/research/BD-0003_PHASE_BACKLOG_TRACEABILITY_MATRIX.md`
Scope: Phases 21–24 (Build Verification, Smoke Testing, Integration Gaps, Pre-Release Polish)

**Matrix convention.** Same eleven third-level fields as BD-0003. Boring is good. Boring ships.

**Primary source anchors:** `docs/BD-0074_FINAL_RELEASE_ACCEPTANCE_PIPELINE.md`; `docs/BD-0075_0093_BUILD_THROUGH_PREVIEW_PIPELINE.md`; `plans/ELIXIR_CLI_AGENT_PHASED_IMPLEMENTATION.md`; `docs/adr/README.md`; root `mix.exs` aliases; `tools/check_release_acceptance.sh`; `tools/smoke_first_mile.sh`; `tools/check_web_removability.sh`.

## Phase 21
### Phase intent
Build verification: confirm the entire codebase compiles warning-free, all tests pass, the standalone boundary holds, the release assembles, and the BD-0074 acceptance pipeline completes.
### Source anchors/citations
`docs/BD-0074_FINAL_RELEASE_ACCEPTANCE_PIPELINE.md`; `tools/check_release_acceptance.sh`; `tools/smoke_first_mile.sh`; root `mix.exs` aliases; `docs/adr/0001-standalone-cli-boundary.md`.
### Related backlog IDs/issues
`tet-db6.75` / `BD-0075`; `tet-db6.76` / `BD-0076`; `tet-db6.77` / `BD-0077`; `tet-db6.78` / `BD-0078`; `tet-db6.79` / `BD-0079`; `tet-db6.80` / `BD-0080`.
### Architecture decisions/ADRs
`ADR-0001` for standalone CLI boundary; `ADR-0002` for Phoenix removability; `ADR-0005` for release gates; `ADR-0009` for SQLite adapter choice.
### Acceptance gates
Format exits 0; compile with warnings-as-errors exits 0; full test suite exits 0; standalone.check exits 0; release assembles with no web closure; release.acceptance pipeline exits 0 with all gates green.
### Verification plan
Run each BD's verification command in dependency order: BD-0075 → BD-0076 → BD-0077 → BD-0078 → BD-0079 → BD-0080. BD-0080 subsumes all prior gates.
### Deliverables/artifacts
Clean format output; zero-warning compile log; full test report; standalone check report; release artifact at `_build/prod/rel/tet_standalone/`; acceptance pipeline report.
### Dependencies
Phase 20 (BD-0074) defines the acceptance pipeline this phase exercises; all prior phases (0–20) define the codebase being verified.
### Risks/conflicts
The SQLite migration from JSONL may have introduced store contract mismatches that cascade through runtime and CLI tests. Mitigation: triage test failures by app starting from store → runtime → CLI. Format drift from large codegen is cheap to fix but annoying to discover last.
### CLI-first/Phoenix-optional implications
The standalone release must build and smoke without Phoenix. Web removability is verified as part of BD-0080/BD-0085.
### Completion evidence
`mix release.acceptance` exit 0 transcript; release artifact listing; first-mile smoke transcript.

## Phase 22
### Phase intent
Smoke testing: exercise real end-to-end product paths through the assembled release binary, including mock and real provider sessions, doctor diagnostics, SQLite durability, and web removability regression.
### Source anchors/citations
`README.md` smoke test section; `docs/README.md` session/provider/doctor documentation; `tools/smoke_first_mile.sh`; `tools/check_web_removability.sh`; `apps/tet_runtime/lib/tet/runtime/provider/anthropic.ex`; `apps/tet_runtime/lib/tet/runtime/provider/openai_compatible.ex`.
### Related backlog IDs/issues
`tet-db6.81` / `BD-0081`; `tet-db6.82` / `BD-0082`; `tet-db6.83` / `BD-0083`; `tet-db6.84` / `BD-0084`; `tet-db6.85` / `BD-0085`.
### Architecture decisions/ADRs
`ADR-0001` for CLI as primary interface; `ADR-0003` for provider termination at adapters; `ADR-0006` for `.tet/` storage; `ADR-0009` for SQLite durability; `ADR-0002` for web removability.
### Acceptance gates
Mock provider session lifecycle completes with all messages persisted; real provider streaming produces complete responses; doctor reports accurate diagnostics under all configurations; SQLite data survives process termination; web removability sandbox passes.
### Verification plan
Run BD-0081 mock smoke first; BD-0082 real provider requires operator-supplied API keys and is manual-only; BD-0083 doctor covers multiple config permutations; BD-0084 involves process termination and restart; BD-0085 uses the existing removability script.
### Deliverables/artifacts
Mock session transcripts; real provider session transcripts (manual); doctor output under multiple configs; SQLite durability test evidence; web removability report.
### Dependencies
Phase 21 (BD-0080) must pass first — no smoke testing without a passing build and assembled release.
### Risks/conflicts
Real provider smoke (BD-0082) depends on external API availability and valid credentials. Mitigation: this is explicitly manual and not required for CI. SQLite durability (BD-0084) requires careful process management to avoid test pollution.
### CLI-first/Phoenix-optional implications
All smoke tests run through the CLI release binary. No web endpoint is tested. Web removability proves the standalone path is self-sufficient.
### Completion evidence
Session transcripts, doctor output captures, SQLite inspection showing persisted data, and web removability exit-0 report.

## Phase 23
### Phase intent
Integration gap closure: resolve hook system stubs, verify Anthropic provider streaming maturity, test the JSONL importer against real data shapes, and complete or document migration execute flow stubs.
### Source anchors/citations
`apps/tet_core/test/tet/plan_mode/invariants_gate_test.exs` (BD-0024 stubs); `apps/tet_runtime/lib/tet/runtime/provider/anthropic.ex`; `apps/tet_store_sqlite/lib/tet/store/sqlite/importer.ex`; `apps/tet_store_sqlite/DESIGN_SQLITE_MIGRATION.md`; `apps/tet_core/lib/tet/migration.ex`.
### Related backlog IDs/issues
`tet-db6.86` / `BD-0086`; `tet-db6.87` / `BD-0087`; `tet-db6.88` / `BD-0088`; `tet-db6.89` / `BD-0089`.
### Architecture decisions/ADRs
`ADR-0005` for hook/gate integration; `ADR-0003` for provider adapter termination; `ADR-0009` for SQLite migration path; `ADR-0006` for storage boundaries.
### Acceptance gates
Hook stubs resolved or documented; Anthropic adapter passes fixture and real-provider tests; JSONL importer handles all entity types idempotently; migration stubs implemented or deferred with clear errors.
### Verification plan
BD-0086: run plan mode + hook manager tests; BD-0087: run Anthropic test suite + manual real-provider smoke; BD-0088: run SQLite importer tests with fixture data; BD-0089: run migration tests and audit stubs.
### Deliverables/artifacts
Updated hook integration tests; Anthropic provider fixture suite; importer test fixtures covering all entity types; migration stub audit with disposition (implemented or documented-deferred).
### Dependencies
BD-0077 (test suite pass) is prerequisite for BD-0086 and BD-0089; BD-0082 (real provider) informs BD-0087; BD-0084 (SQLite durability) informs BD-0088.
### Risks/conflicts
Hook integration may require design decisions about gate-hook coupling that affect the plan mode architecture. Anthropic API changes may break SSE parsing. JSONL import edge cases are hard to predict without real-world data.
### CLI-first/Phoenix-optional implications
All integration work stays in core/runtime boundaries. No web-specific gaps identified.
### Completion evidence
Updated test output for hooks, Anthropic fixture replay, importer idempotency evidence, migration stub disposition report.

## Phase 24
### Phase intent
Pre-release polish: run the security compliance suite, verify documentation accuracy, establish release size/startup budgets, and audit user-facing error messages for quality.
### Source anchors/citations
`apps/tet_core/lib/tet/security/compliance_suite.ex`; `apps/tet_core/lib/tet/docs.ex`; `apps/tet_core/lib/tet/docs/topic.ex`; `apps/tet_cli/lib/tet/cli/help_formatter.ex`; `docs/BD-0073_DOCUMENTATION_AND_CLI_HELP.md`; root `mix.exs` release config.
### Related backlog IDs/issues
`tet-db6.90` / `BD-0090`; `tet-db6.91` / `BD-0091`; `tet-db6.92` / `BD-0092`; `tet-db6.93` / `BD-0093`.
### Architecture decisions/ADRs
`ADR-0005` for security gates; `ADR-0001` for CLI as primary interface; `ADR-0006` for storage documentation; `ADR-0008` for error recovery documentation.
### Acceptance gates
Security compliance exits 0 with no findings; all 10 documentation topics match current implementation; release size and startup time are within budget; every user-facing error is actionable and Elixir-internals-free.
### Verification plan
BD-0090: run `mix security.compliance` + fuzzer test suites; BD-0091: cross-reference `tet help` with CLI dispatch; BD-0092: measure release size, startup time, first-ask latency; BD-0093: manual fault injection through release binary.
### Deliverables/artifacts
Security compliance report; documentation accuracy checklist; release budget baseline document; error message audit with before/after for any fixes.
### Dependencies
BD-0078 (standalone.check) for BD-0090; BD-0081 (mock smoke) for BD-0091 and BD-0093; BD-0079 (release) for BD-0092.
### Risks/conflicts
Security fuzzers may find real issues that block release — this is a feature, not a bug. Documentation drift is likely given the scope of implementation. Error messages may require CLI render changes.
### CLI-first/Phoenix-optional implications
All polish work targets the standalone CLI product. Documentation must accurately represent CLI-first usage patterns.
### Completion evidence
Clean security compliance output, documentation accuracy sign-off, baseline performance measurements, error audit report with zero raw-exception user-facing outputs.

## Backlog item detail

### BD-0075: Format verification
- Category: verifying
- Phase: 21 / Build verification
- Depends on: BD-0074
- Description: Run `mix format --check-formatted` and fix any drift.
- Acceptance criteria: Format exits 0 with no diff output.
- Verification: `mix format --check-formatted`
- Source references: Root `mix.exs`; `.formatter.exs`

### BD-0076: Compile clean with warnings-as-errors
- Category: verifying
- Phase: 21 / Build verification
- Depends on: BD-0075
- Description: Compile umbrella with `--warnings-as-errors` in test and prod.
- Acceptance criteria: Zero warnings in both environments.
- Verification: `MIX_ENV=test mix compile --warnings-as-errors` and `MIX_ENV=prod mix compile --warnings-as-errors`
- Source references: `tools/check_release_acceptance.sh`

### BD-0077: Full ExUnit test suite pass
- Category: verifying
- Phase: 21 / Build verification
- Depends on: BD-0076
- Description: Run `mix test` across all apps. Fix failures, do not delete tests.
- Acceptance criteria: `mix test` exits 0. Zero failures.
- Verification: `mix test`
- Source references: All `test/` directories under `apps/`

### BD-0078: Standalone boundary check
- Category: verifying
- Phase: 21 / Build verification
- Depends on: BD-0077
- Description: Run `mix standalone.check` (format + facade + security + tests + closure).
- Acceptance criteria: All sub-gates pass.
- Verification: `mix standalone.check`
- Source references: Root `mix.exs`; `tools/check_web_facade_contract.sh`; `tools/check_release_closure.sh`

### BD-0079: Release assembly
- Category: acting
- Phase: 21 / Build verification
- Depends on: BD-0078
- Description: Build production release with no web applications in closure.
- Acceptance criteria: Release artifact exists; closure is web-free.
- Verification: `MIX_ENV=prod mix release tet_standalone --overwrite` then `tools/check_release_closure.sh --no-build`
- Source references: Root `mix.exs` release config; `apps/tet_cli/lib/tet/cli/release.ex`

### BD-0080: Full release acceptance pipeline
- Category: verifying
- Phase: 21 / Build verification
- Depends on: BD-0079
- Description: Run BD-0074's complete gate via `mix release.acceptance`.
- Acceptance criteria: All gates pass including first-mile smoke.
- Verification: `mix release.acceptance`
- Source references: `docs/BD-0074_FINAL_RELEASE_ACCEPTANCE_PIPELINE.md`

### BD-0081: Mock provider end-to-end session lifecycle
- Category: verifying
- Phase: 22 / Smoke testing
- Depends on: BD-0080
- Description: Full session lifecycle with mock provider through release binary.
- Acceptance criteria: Create, send, resume, list, show, events all work.
- Verification: See BD-0075_0093 master doc for full command sequence.
- Source references: `README.md`; `tools/smoke_first_mile.sh`

### BD-0082: Real provider streaming verification
- Category: verifying
- Phase: 22 / Smoke testing
- Depends on: BD-0081
- Description: Stream chat against OpenAI-compatible and/or Anthropic. Manual only.
- Acceptance criteria: Complete responses persisted; incomplete streams rejected.
- Verification: Manual with real API keys.
- Source references: `apps/tet_runtime/lib/tet/runtime/provider/anthropic.ex`; `apps/tet_runtime/lib/tet/runtime/provider/openai_compatible.ex`

### BD-0083: Doctor diagnostics under varied configurations
- Category: verifying
- Phase: 22 / Smoke testing
- Depends on: BD-0081
- Description: Run `tet doctor` under healthy, missing-key, and bad-path configs.
- Acceptance criteria: Doctor output matches docs; exit codes are correct.
- Verification: See BD-0075_0093 master doc for config permutations.
- Source references: `apps/tet_runtime/lib/tet/runtime/doctor.ex`

### BD-0084: SQLite durability and session resume integrity
- Category: verifying
- Phase: 22 / Smoke testing
- Depends on: BD-0081
- Description: Verify data survives process termination and WAL mode is active.
- Acceptance criteria: Messages, events, autosaves persist across restarts.
- Verification: Send messages → kill BEAM → restart → verify through CLI.
- Source references: `apps/tet_store_sqlite/lib/tet/store/sqlite.ex`; `apps/tet_store_sqlite/test/crash_recovery_test.exs`

### BD-0085: Web removability regression
- Category: verifying
- Phase: 22 / Smoke testing
- Depends on: BD-0080
- Description: Full sandbox removability gate for `tet_web_phoenix`.
- Acceptance criteria: Script exits 0; synthetic leak detected.
- Verification: `tools/check_web_removability.sh`
- Source references: `docs/BD-0009_WEB_REMOVABILITY_GATE.md`

### BD-0086: Hook system integration wiring
- Category: acting
- Phase: 23 / Integration gap closure
- Depends on: BD-0077
- Description: Resolve BD-0024 stubs in plan mode gate tests.
- Acceptance criteria: All stubs replaced or documented as intentionally decoupled.
- Verification: `mix test apps/tet_core/test/tet/plan_mode/ apps/tet_core/test/tet/hook_manager_test.exs`
- Source references: `apps/tet_core/lib/tet/hook_manager.ex`; `apps/tet_core/test/tet/plan_mode/invariants_gate_test.exs`

### BD-0087: Anthropic provider real-world streaming maturity
- Category: acting
- Phase: 23 / Integration gap closure
- Depends on: BD-0082
- Description: Verify all SSE event types, error handling, and incomplete stream rejection.
- Acceptance criteria: Fixture suite covers all event types; real smoke works.
- Verification: `mix test apps/tet_runtime/test/tet/provider_anthropic_test.exs` + manual smoke
- Source references: `apps/tet_runtime/lib/tet/runtime/provider/anthropic.ex`

### BD-0088: Legacy JSONL importer verification
- Category: verifying
- Phase: 23 / Integration gap closure
- Depends on: BD-0084
- Description: Verify importer against all entity types, idempotency, malformed data.
- Acceptance criteria: All entity types import; double-import is safe; bad lines skip.
- Verification: `mix test apps/tet_store_sqlite/`
- Source references: `apps/tet_store_sqlite/lib/tet/store/sqlite/importer.ex`; `apps/tet_store_sqlite/DESIGN_SQLITE_MIGRATION.md`

### BD-0089: Migration execute flow completion
- Category: acting
- Phase: 23 / Integration gap closure
- Depends on: BD-0077
- Description: Audit and resolve stubs in `Tet.Migration` execute path.
- Acceptance criteria: Stubs implemented or documented-deferred with clear errors.
- Verification: `mix test apps/tet_core/test/tet/migration/`
- Source references: `apps/tet_core/lib/tet/migration.ex`

### BD-0090: Security compliance suite execution
- Category: verifying
- Phase: 24 / Pre-release polish
- Depends on: BD-0078
- Description: Run compliance suite, fuzzers, and redactor tests.
- Acceptance criteria: All security gates pass; no escapes or leaks.
- Verification: `mix security.compliance` + security test suites
- Source references: `apps/tet_core/lib/tet/security/compliance_suite.ex`

### BD-0091: Documentation topic accuracy and completeness
- Category: documenting
- Phase: 24 / Pre-release polish
- Depends on: BD-0081
- Description: Cross-reference all 10 help topics against current implementation.
- Acceptance criteria: All current commands exist; future commands are marked.
- Verification: Cross-reference `tet help` output with CLI dispatch.
- Source references: `apps/tet_core/lib/tet/docs.ex`; `docs/BD-0073_DOCUMENTATION_AND_CLI_HELP.md`

### BD-0092: Release binary size and startup performance budget
- Category: verifying
- Phase: 24 / Pre-release polish
- Depends on: BD-0079
- Description: Measure release size, startup time, first-ask latency.
- Acceptance criteria: Baselines documented; no obvious bloat.
- Verification: Size measurement, timed startup, dependency audit.
- Source references: Root `mix.exs`; `apps/tet_cli/lib/tet/cli/release.ex`

### BD-0093: User-facing error message quality audit
- Category: verifying
- Phase: 24 / Pre-release polish
- Depends on: BD-0081
- Description: Trigger every error path and verify user-friendly output.
- Acceptance criteria: No raw exceptions, stack traces, or cryptic atoms in user output.
- Verification: Manual fault injection through release binary.
- Source references: `apps/tet_cli/lib/tet/cli.ex`; `apps/tet_cli/lib/tet/cli/render.ex`
