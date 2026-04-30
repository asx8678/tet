# BD-0003 Phase/backlog traceability matrix

Issue: `tet-db6.3` / `BD-0003: Phase/backlog traceability matrix`
Branch: `feature/tet-db6-3-traceability-matrix`
Scope: documentation only; no implementation code, release files, migrations, generated app skeletons, or runtime source.

**Matrix convention.** Each numbered phase section uses the same eleven third-level fields: phase intent, citations, related backlog, ADRs, acceptance gates, verification plan, deliverables, dependencies, risks, CLI/Phoenix implications, and completion evidence. This deliberately boring shape keeps review and grep checks simple. Boring is good. Boring ships.

**Primary source anchors used throughout:** `/Users/adam2/projects/tet/prompt.md`; `plans/ELIXIR_CLI_AGENT_PHASED_IMPLEMENTATION.md`; `plans/ELIXIR_CLI_AGENT_GLOBAL_VISION.md`; `docs/research/BD-0001_SOURCE_INVENTORY_AND_MISSING_INPUT_REPORT.md`; `docs/adr/README.md`; `docs/adr/0001-standalone-cli-boundary.md`; `docs/adr/0002-phoenix-optional-adapter.md`; `docs/adr/0003-custom-otp-first-runtime.md`; `docs/adr/0004-universal-agent-runtime-boundary.md`; `docs/adr/0005-gates-approvals-verification.md`; `docs/adr/0006-storage-names-and-boundaries.md`; `docs/adr/0007-remote-execution-boundary.md`; `docs/adr/0008-repair-and-error-recovery.md`.
## Phase 0
### Phase intent
Repository research and architecture decision record: establish verified source inventory, missing-source boundaries, ADR decisions, phase order, and BD traceability before implementation work begins.
### Source anchors/citations
`/Users/adam2/projects/tet/prompt.md`; `plans/ELIXIR_CLI_AGENT_PHASED_IMPLEMENTATION.md`; `docs/research/BD-0001_SOURCE_INVENTORY_AND_MISSING_INPUT_REPORT.md`; `docs/adr/README.md`; `bd show tet-d1c` as cited by the phased plan.
### Related backlog IDs/issues
`tet-db6.1` / `BD-0001`; `tet-db6.2` / `BD-0002`; `tet-db6.3` / `BD-0003`.
### Architecture decisions/ADRs
All Phase 0 decisions are embodied in `docs/adr/0001-standalone-cli-boundary.md` through `docs/adr/0008-repair-and-error-recovery.md`, indexed by `docs/adr/README.md`.
### Acceptance gates
All mandatory sources are cited or explicitly marked missing; CLI-first/Phoenix-optional boundaries are accepted; renamed state terms are reserved; no implementation files are produced.
### Verification plan
Check source existence with `test -e`; inspect `bd show tet-d1c`; grep this matrix for the numbered phase sections; verify each phase has the same eleven fields; review `git diff --stat` for Markdown-only documentation changes.
### Deliverables/artifacts
Source inventory, ADR bundle, this traceability matrix, and a research index linking Phase 0 documentation artifacts.
### Dependencies
Base branch `main`; completed `BD-0001`; completed `BD-0002`; external prompt source at `/Users/adam2/projects/tet/prompt.md`.
### Risks/conflicts
Missing G-domain/agent-domain and exact LLExpert inputs can tempt invented citations; mitigation is to cite only verified paths and mark unavailable families, as `BD-0001` already does.
### CLI-first/Phoenix-optional implications
Phase 0 freezes the rule that CLI/runtime/core are the product spine and Phoenix is only a removable adapter.
### Completion evidence
Merged `BD-0001` report, accepted ADR set, this committed matrix, verification command output, and a clean docs-only diff.
## Phase 1
### Phase intent
Standalone Elixir CLI MVP: create the smallest Phoenix-free CLI/runtime path that configures one provider, sends a prompt, streams text, persists history, and resumes a session.
### Source anchors/citations
`/Users/adam2/projects/tet/prompt.md`; `plans/ELIXIR_CLI_AGENT_PHASED_IMPLEMENTATION.md`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/cli_runner.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/config.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/session_storage.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/model_factory.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/models.json`.
### Related backlog IDs/issues
`tet-db6.4` / `BD-0004`; `tet-db6.5` / `BD-0005`; `tet-db6.6` / `BD-0006`.
### Architecture decisions/ADRs
`ADR-0001` for standalone CLI facade; `ADR-0003` for OTP-first runtime; `ADR-0006` for `.tet/` storage names; `ADR-0002` as a negative boundary excluding Phoenix from the standalone closure.
### Acceptance gates
User can configure one provider, start a session, stream a response, quit, resume, inspect events, and build/run without Phoenix/Plug/Cowboy/LiveView.
### Verification plan
Future checks: `mix test`; standalone release build; `tet doctor`; mocked-provider chat smoke; dependency-closure grep proving no web dependency in the standalone release.
### Deliverables/artifacts
Conceptual umbrella/release boundary, CLI command surface, config/secrets shape, one-provider stream path, session store contract, first-run/doctor UX.
### Dependencies
Phase 0 matrix and ADRs; `BD-0004` blocks `BD-0005`, which blocks `BD-0006`.
### Risks/conflicts
Provider auth and streaming edge cases may bloat the MVP; mitigation is mock-provider CI plus a single OpenAI-compatible real-provider smoke path.
### CLI-first/Phoenix-optional implications
Phoenix is not present, not linked, and not needed; any browser idea waits until the CLI path works.
### Completion evidence
Release artifact, mocked chat transcript, persisted session fixture, `tet doctor` output, and dependency closure report.
## Phase 2
### Phase intent
Optional Phoenix LiveView shell: add a removable web adapter that observes and controls core sessions only through the public runtime facade.
### Source anchors/citations
`/Users/adam2/projects/tet/prompt.md`; `plans/ELIXIR_CLI_AGENT_PHASED_IMPLEMENTATION.md`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/api/app.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/api/websocket.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/messaging/bus.py`; `/Users/adam2/projects/tet/check this plans/plan 3/plan/docs/01_architecture.md`; `/Users/adam2/projects/tet/check this plans/plan 3/plan/docs/09_phoenix_optional_module.md`.
### Related backlog IDs/issues
`tet-db6.7` / `BD-0007`; `tet-db6.8` / `BD-0008`; `tet-db6.9` / `BD-0009`.
### Architecture decisions/ADRs
`ADR-0001` for `Tet.*` facade ownership; `ADR-0002` for removable Phoenix; `ADR-0003` for runtime-owned side effects.
### Acceptance gates
Deleting or excluding `tet_web_phoenix` leaves CLI compile/test/release intact; LiveView calls only `Tet.*`; every web-visible item has CLI/log parity.
### Verification plan
Future checks: xref/dependency guard for forbidden edges; standalone release closure; LiveView smoke with fake events; CLI parity snapshot for the same event timeline.
### Deliverables/artifacts
Optional app boundary spec, minimal event timeline shell, facade-only call list, release-profile split, and removability test plan.
### Dependencies
Phase 1 runtime/facade/session events; `BD-0007` facade contract before `BD-0008` shell and `BD-0009` gate.
### Risks/conflicts
Web convenience may leak policy or state into LiveView; mitigation is facade-only tests and rejecting web-owned runtime logic.
### CLI-first/Phoenix-optional implications
Phoenix renders Tet; Phoenix does not own Tet. The standalone CLI remains the acceptance baseline.
### Completion evidence
Removability CI result, facade-only test output, event timeline screenshot/snapshot, and CLI-equivalent transcript.
## Phase 3
### Phase intent
Code Puppy-style prompt/session system: add prompt composition, prompt review/refinement, attachments, history compaction, autosave, restore, and prompt debug artifacts.
### Source anchors/citations
`/Users/adam2/projects/tet/prompt.md`; `plans/ELIXIR_CLI_AGENT_PHASED_IMPLEMENTATION.md`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/base_agent.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/_builder.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/_runtime.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/_history.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/_compaction.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/prompt_reviewer.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/session_storage.py`.
### Related backlog IDs/issues
`tet-db6.10` / `BD-0010`; `tet-db6.11` / `BD-0011`; `tet-db6.12` / `BD-0012`.
### Architecture decisions/ADRs
`ADR-0003` for runtime-owned prompt/session side effects; `ADR-0004` for durable session state around the Universal Agent Runtime; `ADR-0006` for Session Memory, Task Memory, Compacted Context, and Artifact Store names.
### Acceptance gates
Prompt build is deterministic and debuggable; attachments survive resume; compaction preserves system prompt, recent context, tool-call/result integrity, and cache metadata; redaction occurs before provider payloads.
### Verification plan
Future checks: prompt layer snapshot tests; attachment restore fixture; compaction split tests; prompt-review fixtures; redaction tests before provider call/log/display.
### Deliverables/artifacts
Prompt Composer contract, Prompt Refiner/Reviewer workflow, attachment metadata model, Compacted Context policy, autosave/restore flow, prompt debug artifact format.
### Dependencies
Phase 1 sessions/config/provider path; Phase 4 later expands cache/provider semantics but Phase 3 records cache hints as metadata.
### Risks/conflicts
Overbuilding Prompt Lab too early; mitigation is core composer/review/debug here and richer command correction later in Phase 14.
### CLI-first/Phoenix-optional implications
CLI exposes attach, prompt review, prompt debug, and restore; any Phoenix view is only an observer/controller through `Tet.*`.
### Completion evidence
Prompt debug snapshots, restored attachment fixture, compaction test output, and redaction fixture results.
## Phase 4
### Phase intent
Model router and provider parity: normalize provider registry, adapters, streaming events, structured outputs, fallback, round-robin, model pins, cost, latency, and telemetry.
### Source anchors/citations
`/Users/adam2/projects/tet/prompt.md`; `plans/ELIXIR_CLI_AGENT_PHASED_IMPLEMENTATION.md`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/model_factory.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/models.json`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/round_robin_model.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/claude_cache_client.py`; `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/upgrades/11_provider_contract.md`; `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/upgrades/13_operations_and_telemetry.md`.
### Related backlog IDs/issues
`tet-db6.13` / `BD-0013`; `tet-db6.14` / `BD-0014`; `tet-db6.15` / `BD-0015`.
### Architecture decisions/ADRs
`ADR-0003` for adapter termination behind runtime contracts; `ADR-0004` for profile model pins/cache-hint handling; `ADR-0005` for auditable provider/tool events.
### Acceptance gates
Registry validates model capabilities; adapters emit the same normalized stream shape; provider errors become events not crashes; fallback and round-robin choices are deterministic and auditable.
### Verification plan
Future checks: registry validation tests; provider fixture replay with fake/no-network CI; retry/backoff unit tests; structured-output conformance; telemetry assertions.
### Deliverables/artifacts
ModelRouter spec, ProviderAdapter behavior, StructuredOutputLayer contract, registry schema, fallback policy, telemetry event list, provider conformance fixtures.
### Dependencies
Phase 1 stream path and Phase 3 prompt/session context; `BD-0013` schema informs `BD-0014` adapters and `BD-0015` router behavior.
### Risks/conflicts
Provider sprawl can explode scope; mitigation is a strict adapter contract plus incremental provider additions behind conformance tests.
### CLI-first/Phoenix-optional implications
CLI owns `tet models` and provider diagnostics; Phoenix may display provider status later but cannot call provider adapters directly.
### Completion evidence
Passing fake-provider fixture suite, validated model registry, router decision audit events, and telemetry sample output.
## Phase 5
### Phase intent
Universal Agent Runtime and profile switching: run one long-lived session orchestration boundary that hot-swaps profiles while preserving durable session context.
### Source anchors/citations
`/Users/adam2/projects/tet/prompt.md`; `plans/ELIXIR_CLI_AGENT_PHASED_IMPLEMENTATION.md`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/base_agent.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/_builder.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/_runtime.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/agent_manager.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/json_agent.py`; `/Users/adam2/projects/tet/source/jido-main/README.md`.
### Related backlog IDs/issues
`tet-db6.16` / `BD-0016`; `tet-db6.17` / `BD-0017`; `tet-db6.18` / `BD-0018`; `tet-db6.19` / `BD-0019`.
### Architecture decisions/ADRs
`ADR-0004` is primary; `ADR-0003` keeps lifecycle in custom OTP; `ADR-0005` keeps swaps inside gates; `ADR-0006` keeps durable state terms authoritative.
### Acceptance gates
Safe turn-boundary swaps preserve history, attachments, Session Memory, Task Memory, artifacts, approvals, and cache-hint status; unsafe mid-turn/tool/approval swaps are queued or rejected with events.
### Verification plan
Future checks: profile state-machine tests; planner-to-coder-to-reviewer-to-tester fixture; provider cache capability tests; compaction fallback tests; event ordering assertions.
### Deliverables/artifacts
Runtime state model, profile descriptor schema, registry, hot-swap state machine, cache/context preservation rules, profile lifecycle events.
### Dependencies
Phase 3 prompt/session state and Phase 4 provider/router model pins; `BD-0016` and `BD-0017` precede `BD-0018`/`BD-0019`.
### Risks/conflicts
Provider cache preservation is conditional; mitigation is explicit adapter capability reporting and durable preserved/summarized/reset outcomes.
### CLI-first/Phoenix-optional implications
CLI exposes profiles and profile switching; optional Phoenix may initiate swaps only through `Tet.*` and cannot own profile semantics.
### Completion evidence
Swap fixture transcript, profile registry validation, cache outcome events, and no unsafe mid-flight swap evidence.
## Phase 6
### Phase intent
Read-only tool layer: provide safe file/repo inspection and ask-user capabilities with structured contracts, path containment, redaction, bounded output, and event capture.
### Source anchors/citations
`/Users/adam2/projects/tet/prompt.md`; `plans/ELIXIR_CLI_AGENT_PHASED_IMPLEMENTATION.md`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/tools/__init__.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/tools/file_operations.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/tools/ask_user_question/handler.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/tools/browser/browser_screenshot.py`; `/Users/adam2/projects/tet/check this plans/tet agent_platform_minimal_core.md`.
### Related backlog IDs/issues
`tet-db6.20` / `BD-0020`; `tet-db6.21` / `BD-0021`; `tet-db6.22` / `BD-0022`.
### Architecture decisions/ADRs
`ADR-0005` for gate/event capture; `ADR-0006` for Artifact Store/Event Log names; `ADR-0003` for runtime-owned tool executors.
### Acceptance gates
Read/list/search/git-diff/ask-user cannot mutate, cannot escape workspace policy, redact sensitive data, truncate bounded outputs, and persist task/session-correlated events.
### Verification plan
Future checks: path traversal fuzz tests; deny-glob tests; large-output truncation fixtures; redaction tests; read-only mode policy tests; Event Log assertions.
### Deliverables/artifacts
Read-only tool catalog, typed tool behavior, path resolver policy, output redaction/truncation rules, CLI renderers, read tool event schema.
### Dependencies
Phase 5 runtime/profile tool allowlists; Phase 7 later tightens task enforcement, but read tools already record event hooks.
### Risks/conflicts
Read-only can still leak secrets; mitigation is deny globs, layered redaction, artifact privacy classes, and bounded outputs.
### CLI-first/Phoenix-optional implications
CLI exploration is the default interface; optional Phoenix can render read artifacts later but must not bypass runtime tool policy.
### Completion evidence
Tool contract tests, path fuzz results, redaction artifacts, and persisted read-tool Event Log entries.
## Phase 7
### Phase intent
Hook system, task enforcement, and plan mode: enforce deterministic task gates, priority hooks, plan-mode restrictions, guidance, and the five cross-phase invariants.
### Source anchors/citations
`/Users/adam2/projects/tet/prompt.md`; `plans/ELIXIR_CLI_AGENT_PHASED_IMPLEMENTATION.md`; `/Users/adam2/projects/tet/check this plans/swarm-sdk-architecture.pdf`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/hook_engine/README.md`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/hook_engine/engine.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/callbacks.py`; `/Users/adam2/projects/tet/source/codex-main/codex-rs/hooks/src/engine/dispatcher.rs`.
### Related backlog IDs/issues
`tet-db6.23` / `BD-0023`; `tet-db6.24` / `BD-0024`; `tet-db6.25` / `BD-0025`; `tet-db6.26` / `BD-0026`.
### Architecture decisions/ADRs
`ADR-0005` is primary; `ADR-0003` owns HookManager/TaskManager supervision; `ADR-0004` keeps tasks tied to the runtime; `ADR-0006` names Task Memory/Event Log artifacts.
### Acceptance gates
No mutating/executing tool without active task; category gates work; pre hooks run high-to-low and post hooks low-to-high; guidance follows task operations; blocked attempts are captured.
### Verification plan
Future checks: task state-machine property tests; hook ordering tests; category matrix tests; plan-mode write-block tests; blocked-event persistence tests; guidance snapshots.
### Deliverables/artifacts
Task schema, Hook behavior, HookManager, category-to-tool matrix, plan-mode policy, default hook registry, invariant test suite.
### Dependencies
Phase 6 read tools; task enforcement precedes Phase 8 mutating tools, because safety rails go before scissors. Revolutionary concept.
### Risks/conflicts
Too many hooks can become spooky action at a distance; mitigation is deterministic ordering, typed hook actions, trace events, and small defaults.
### CLI-first/Phoenix-optional implications
CLI exposes `tet task`, `tet plan`, and event tailing; optional Phoenix must use the same task and hook state through `Tet.*`.
### Completion evidence
Invariant CI output, hook trace events, plan-mode blocked attempt artifact, and task transition fixture results.
## Phase 8
### Phase intent
Mutating tools behind gates: add write/edit/patch/shell/git/test execution only after task, category, approval, sandbox, diff, rollback, and audit gates.
### Source anchors/citations
`/Users/adam2/projects/tet/prompt.md`; `plans/ELIXIR_CLI_AGENT_PHASED_IMPLEMENTATION.md`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/tools/file_modifications.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/tools/command_runner.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/plugins/shell_safety/agent_shell_safety.py`; `/Users/adam2/projects/tet/source/codex-main/codex-rs/core/src/exec_policy.rs`; `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/upgrades/12_durable_execution.md`.
### Related backlog IDs/issues
`tet-db6.27` / `BD-0027`; `tet-db6.28` / `BD-0028`; `tet-db6.29` / `BD-0029`; `tet-db6.30` / `BD-0030`.
### Architecture decisions/ADRs
`ADR-0005` is primary for gate/approval/verification; `ADR-0008` adds durable patch recovery; `ADR-0006` names approval/artifact/event storage; `ADR-0003` owns supervised execution.
### Acceptance gates
No mutation without active acting task and approved diff; shell/git/test run only through policy; snapshots support rollback; blocked and approved attempts are auditable.
### Verification plan
Future checks: patch parse/apply/rollback tests; approval state-machine tests; shell policy fixtures; verifier allowlist tests; sandbox path tests; artifacted stdout/stderr assertions.
### Deliverables/artifacts
Approval model, diff artifact format, patch applier contract, rollback snapshots, constrained shell/verifier runner, sandbox policy, audit events.
### Dependencies
Phase 7 task/hook gates; Phase 10 later broadens durability but Phase 8 must snapshot risky writes from day one.
### Risks/conflicts
Raw shell convenience is a bypass trap; mitigation is command-vector normalization, verifier allowlists, approvals, and policy-before-execution.
### CLI-first/Phoenix-optional implications
CLI approvals and patch review are required; Phoenix can render approval UX later but cannot combine approval and execution shortcuts.
### Completion evidence
Patch approval transcript, rollback fixture, verifier artifact, blocked shell event, and policy matrix test output.
## Phase 9
### Phase intent
Steering agent and guidance loop: add a Ring-2 relevance evaluator that can continue, focus, guide, or block after deterministic gates pass.
### Source anchors/citations
`/Users/adam2/projects/tet/prompt.md`; `plans/ELIXIR_CLI_AGENT_PHASED_IMPLEMENTATION.md`; `/Users/adam2/projects/tet/check this plans/swarm-sdk-architecture.pdf`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/prompt_reviewer.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/hook_engine/README.md`; `/Users/adam2/projects/tet/source/codex-main/codex-rs/hooks/src/engine/dispatcher.rs`.
### Related backlog IDs/issues
`tet-db6.31` / `BD-0031`; `tet-db6.32` / `BD-0032`; `tet-db6.33` / `BD-0033`.
### Architecture decisions/ADRs
`ADR-0005` requires deterministic policy before LLM steering and forbids widening permissions; `ADR-0004` keeps steering tied to runtime/session state.
### Acceptance gates
Steering runs after deterministic gates, never overrides blocks, persists guide/focus/block decisions, and includes task/tool rationale visible to the operator.
### Verification plan
Future checks: decision schema validation; deterministic-before-LLM tests; no-override fixtures; guidance rendering snapshots; steering telemetry assertions.
### Deliverables/artifacts
Steering prompt/spec, decision schema, relevance context builder, lightweight evaluator profile, guidance renderer, steering Event Log entries.
### Dependencies
Phase 7 task/hook model and Phase 8 policy context; guidance output depends on durable event capture.
### Risks/conflicts
Steering can add latency or hallucinated blocks; mitigation is a small model/profile, operator toggle, explicit rationale, and deterministic fallback.
### CLI-first/Phoenix-optional implications
CLI renders guidance inline and through events; Phoenix may render the same events but cannot treat steering as policy authority.
### Completion evidence
Decision fixture output, no-override test results, guidance snapshots, and persisted steering events.
## Phase 10
### Phase intent
State, memory, artifacts, and checkpoints: implement durable Event Log, Session Memory, Task Memory, Finding Store, Persistent Memory, Project Lessons, Artifact Store, Error Log, Repair Queue, checkpoints, replay, and retention.
### Source anchors/citations
`/Users/adam2/projects/tet/prompt.md`; `plans/ELIXIR_CLI_AGENT_PHASED_IMPLEMENTATION.md`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/session_storage.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/messaging/bus.py`; `/Users/adam2/projects/tet/source/codex-main/codex-rs/state/migrations/0001_threads.sql`; `/Users/adam2/projects/tet/source/codex-main/codex-rs/state/migrations/0014_agent_jobs.sql`; `/Users/adam2/projects/tet/source/codex-main/codex-rs/thread-store/src/store.rs`; `/Users/adam2/projects/tet/source/codex-main/codex-rs/memories/README.md`; `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/upgrades/12_durable_execution.md`.
### Related backlog IDs/issues
`tet-db6.34` / `BD-0034`; `tet-db6.35` / `BD-0035`; `tet-db6.36` / `BD-0036`; `tet-db6.37` / `BD-0037`.
### Architecture decisions/ADRs
`ADR-0006` is primary for storage names/boundaries; `ADR-0008` for durable recovery; `ADR-0004` for process memory not being authoritative; `ADR-0005` for complete event capture.
### Acceptance gates
Provider/tool/task/approval/error events persist with correlation; checkpoint restore is deterministic; artifacts are addressed and integrity checked; audit-critical records survive retention policy.
### Verification plan
Future checks: store contract tests across memory/SQLite; event ordering tests; workflow replay tests; checkpoint round-trip; artifact hash tests; retention fixtures; forbidden deprecated memory-term grep.
### Deliverables/artifacts
Storage entity map, store behavior extensions, Event Log schema, Artifact Store addressing, checkpoint format, resume/replay decision tree, retention policy.
### Dependencies
Phases 3, 7, and 8 produce session/task/tool/approval events; Phase 17 later activates repair workflow over Error Log and Repair Queue.
### Risks/conflicts
Unbounded logs and vague memory names can rot the product; mitigation is retention classes, compaction, Project Lessons promotion, and reserved terms from `ADR-0006`.
### CLI-first/Phoenix-optional implications
CLI can inspect events, artifacts, checkpoints, and memory; optional Phoenix consumes the same durable projections.
### Completion evidence
Store contract report, replay fixture, checkpoint restore transcript, artifact integrity output, and retention policy tests.
## Phase 11
### Phase intent
Code Puppy specialized profile parity: map Code Puppy planners, reviewers, QA, security, packager/retriever, JSON/data, and repair behavior into Tet profiles or bounded workers.
### Source anchors/citations
`/Users/adam2/projects/tet/prompt.md`; `plans/ELIXIR_CLI_AGENT_PHASED_IMPLEMENTATION.md`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/agent_manager.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/agent_planning.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/agent_qa_expert.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/agent_security_auditor.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/pack/shepherd.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/pack/watchdog.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/pack/retriever.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/json_agent.py`.
### Related backlog IDs/issues
`tet-db6.38` / `BD-0038`; `tet-db6.39` / `BD-0039`; `tet-db6.40` / `BD-0040`.
### Architecture decisions/ADRs
`ADR-0004` maps named agents to data profiles; `ADR-0005` prevents profile gate bypass; `ADR-0003` keeps runtime ownership custom OTP-first.
### Acceptance gates
Every discovered Code Puppy specialty is mapped or explicitly deferred; profile swaps preserve durable session state; structured-output profiles validate; reviewer/tester/security cannot bypass tool gates.
### Verification plan
Future checks: source-to-profile parity matrix review; profile registry tests; prompt overlay snapshots; structured-output validation; security/reviewer/tester fake-provider fixtures.
### Deliverables/artifacts
Profile parity matrix, profile prompt/tool/model overlays, JSON/data schema profile, reviewer/tester/security workflows, profile QA fixture set.
### Dependencies
Phase 5 runtime/profile registry and Phase 4 structured-output/provider support; Phase 13 later adds parallel helper execution.
### Risks/conflicts
Copying prompts verbatim may raise licensing or quality concerns; mitigation is behavior-level parity, source citation, and rewritten project-owned prompts where needed.
### CLI-first/Phoenix-optional implications
CLI profile commands remain first-class; Phoenix may display/switch profiles only through `Tet.*`.
### Completion evidence
Published parity matrix, validated profile registry, structured-output fixture results, and profile gate test output.
## Phase 12
### Phase intent
MCP integration: load MCP servers as health-checked, namespaced, policy-gated typed tools with lifecycle, reload, conflict handling, trust, and audit capture.
### Source anchors/citations
`/Users/adam2/projects/tet/prompt.md`; `plans/ELIXIR_CLI_AGENT_PHASED_IMPLEMENTATION.md`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/mcp_/manager.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/command_line/mcp/status_command.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/_builder.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/tools/__init__.py`; `/Users/adam2/projects/tet/source/codex-main/codex-rs/core/src/mcp_tool_call.rs`.
### Related backlog IDs/issues
`tet-db6.41` / `BD-0041`; `tet-db6.42` / `BD-0042`; `tet-db6.43` / `BD-0043`.
### Architecture decisions/ADRs
`ADR-0005` is primary for gates and trust; `ADR-0003` keeps MCP behind runtime adapters; `ADR-0004` ties MCP allowlists to profiles; `ADR-0006` stores events/artifacts.
### Acceptance gates
Servers load only when enabled and healthy; duplicate tool names cannot shadow built-ins; every MCP call passes task/category/policy/approval gates; server failures do not crash sessions.
### Verification plan
Future checks: MCP registry validation; duplicate/conflict tests; health-check fixtures; read/write MCP policy matrix tests; restart/reload tests; audit-event assertions.
### Deliverables/artifacts
MCP registry schema, lifecycle manager, tool namespacing rule, health model, permission classifier, CLI MCP admin UX, MCP tool Event Log schema.
### Dependencies
Phase 7 gate pipeline, Phase 8 mutating approval model, and Phase 10 durable artifacts/events for server output.
### Risks/conflicts
MCP servers are opaque and may mislabel capabilities; mitigation is default-disabled/low-trust posture and Tet-owned classification.
### CLI-first/Phoenix-optional implications
CLI manages MCP servers; Phoenix may display status later but cannot use MCP as a side door around policy.
### Completion evidence
MCP lifecycle fixture output, conflict test logs, policy matrix results, and audit entries for MCP calls.
## Phase 13
### Phase intent
Subagents and parallel helper agents: add bounded fan-out for research/review/testing while preserving the Universal Agent Runtime as parent authority.
### Source anchors/citations
`/Users/adam2/projects/tet/prompt.md`; `plans/ELIXIR_CLI_AGENT_PHASED_IMPLEMENTATION.md`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/tools/agent_tools.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/subagent_stream_handler.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/pack/retriever.py`; `/Users/adam2/projects/tet/source/jido-main/README.md`; `/Users/adam2/projects/tet/source/oh-my-pi-main/README.md`; `docs/research/BD-0001_SOURCE_INVENTORY_AND_MISSING_INPUT_REPORT.md` for missing exact G-domain/agent-domain inputs.
### Related backlog IDs/issues
`tet-db6.44` / `BD-0044`; `tet-db6.45` / `BD-0045`; `tet-db6.46` / `BD-0046`.
### Architecture decisions/ADRs
`ADR-0004` for parent UAR authority; `ADR-0005` for inherited gates; `ADR-0003` for supervised workers; `ADR-0006` for artifact/result routing.
### Acceptance gates
Workers are bounded, cancelable, budgeted, parent-task-correlated, policy-inheriting, artifact-persisting, and deterministically merged by the parent runtime.
### Verification plan
Future checks: worker supervisor tests; fan-out limit tests; cancellation/timeout tests; merge conflict fixtures; parent-task correlation assertions; fake-provider multi-worker smoke.
### Deliverables/artifacts
Subagent lifecycle spec, worker supervisor, merge protocol, artifact routing, budget/cancellation model, quiet/verbose renderers.
### Dependencies
Phase 11 profiles, Phase 10 artifact/event storage, and Phase 7/8 gate policies.
### Risks/conflicts
Parallel workers multiply cost and context chaos; mitigation is default-low concurrency, explicit budgets, summarized results, and parent approval for expensive fan-out.
### CLI-first/Phoenix-optional implications
CLI exposes agent status/cancel and summaries; optional Phoenix can visualize workers but cannot become the parent authority.
### Completion evidence
Fan-out fixture output, cancellation trace, merge artifact, budget enforcement log, and parent correlation events.
## Phase 14
### Phase intent
Prompt Lab / LLExpert-style command correction: add prompt presets/refinement and safe command suggestions that never auto-run dangerous commands.
### Source anchors/citations
`/Users/adam2/projects/tet/prompt.md`; `plans/ELIXIR_CLI_AGENT_PHASED_IMPLEMENTATION.md`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/prompt_reviewer.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/tools/command_runner.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/command_line/shell_passthrough.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/plugins/shell_safety/agent_shell_safety.py`; `/Users/adam2/projects/tet/source/llxprt-code-main/README.md`.
### Related backlog IDs/issues
`tet-db6.47` / `BD-0047`; `tet-db6.48` / `BD-0048`; `tet-db6.49` / `BD-0049`.
### Architecture decisions/ADRs
`ADR-0005` for no unsafe shell execution and approval gates; `ADR-0001` for CLI UX through facade; `ADR-0003` for runtime-owned suggestion service.
### Acceptance gates
Prompt refinements are explainable; command corrections are suggestions only; risky commands require explicit user action plus active task/category/policy approval before execution; all suggestions are logged.
### Verification plan
Future checks: prompt refinement snapshots; command parser tests; dangerous-command risk fixtures; no-auto-run tests; CLI snapshot tests for interactive and JSON output.
### Deliverables/artifacts
Prompt Lab workflow, preset catalog format, prompt quality dimensions, command correction schema, risk renderer, copy/apply/run approval flow.
### Dependencies
Phase 3 prompt review/composer and Phase 8 shell/approval policy; Phase 7 task categories for execution gating.
### Risks/conflicts
Users may mistake suggestions for safe commands; mitigation is risk labels, dry-run previews, no auto-run, and re-checking policy on execution.
### CLI-first/Phoenix-optional implications
Prompt Lab is a CLI-first surface; Phoenix can later render the same suggestions but must not auto-execute them.
### Completion evidence
No-auto-run fixture output, dangerous command risk table, prompt refinement snapshots, and suggestion Event Log records.
## Phase 15
### Phase intent
DX, theming, plugins: improve history, fuzzy completion, themes, plugin loading, and lean packaging while keeping policy and release size under control.
### Source anchors/citations
`/Users/adam2/projects/tet/prompt.md`; `plans/ELIXIR_CLI_AGENT_PHASED_IMPLEMENTATION.md`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/plugins/__init__.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/plugins/agent_skills/discovery.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/command_line/prompt_toolkit_completion.py`; `/Users/adam2/projects/tet/source/oh-my-pi-main/README.md`; `/Users/adam2/projects/tet/source/oh-my-pi-main/docs/custom-tools.md`; `/Users/adam2/projects/tet/source/pi-mono-main/README.md`; `/Users/adam2/projects/tet/source/pi-mono-main/scripts/build-binaries.sh`.
### Related backlog IDs/issues
`tet-db6.50` / `BD-0050`; `tet-db6.51` / `BD-0051`; `tet-db6.52` / `BD-0052`.
### Architecture decisions/ADRs
`ADR-0001` keeps DX in CLI adapter/facade boundaries; `ADR-0003` keeps plugins behind runtime contracts; `ADR-0005` prevents plugin gate bypass; `ADR-0006` governs config/artifact storage.
### Acceptance gates
Plugins declare capabilities and explicit trust; themes affect rendering only; completions are cacheable; standalone release remains lean; disabled plugins do not load.
### Verification plan
Future checks: plugin manifest validation; capability-gate tests; completion snapshots; theme rendering snapshots; release size/startup checks; disabled-plugin tests.
### Deliverables/artifacts
Completion/history UX, theme schema, plugin manifest/capability contract, plugin trust policy, packaging optimization checklist.
### Dependencies
Phase 12 external tool trust concepts, Phase 14 CLI UX, and Phase 7/8 policy gates.
### Risks/conflicts
Plugin loader can become a security hole or bloat factory; mitigation is explicit trust, no arbitrary execution by default, declared capabilities, and release-size checks.
### CLI-first/Phoenix-optional implications
DX improvements target the standalone CLI first; optional Phoenix must not become a hidden dependency for plugin/theme behavior.
### Completion evidence
Plugin capability test output, completion/theme snapshots, startup/size report, and disabled-plugin verification.
## Phase 16
### Phase intent
Remote execution and VPS worker agents: add SSH-based remote workers for heavy tasks while local Tet remains the control plane and policy authority.
### Source anchors/citations
`/Users/adam2/projects/tet/prompt.md`; `plans/ELIXIR_CLI_AGENT_PHASED_IMPLEMENTATION.md`; `/Users/adam2/projects/tet/source/codex-main/codex-rs/exec-server/README.md`; `/Users/adam2/projects/tet/source/codex-main/scripts/test-remote-env.sh`; `/Users/adam2/projects/tet/source/codex-main/codex-rs/core/src/exec_policy.rs`; `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/upgrades/13_operations_and_telemetry.md`; `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/upgrades/14_secrets_and_redaction.md`.
### Related backlog IDs/issues
`tet-db6.53` / `BD-0053`; `tet-db6.54` / `BD-0054`; `tet-db6.55` / `BD-0055`; `tet-db6.56` / `BD-0056`.
### Architecture decisions/ADRs
`ADR-0007` is primary; `ADR-0005` applies gates remotely; `ADR-0008` captures uncertain failures; `ADR-0006` routes remote artifacts/events.
### Acceptance gates
SSH profiles validate host keys and scoped secrets; remote worker reports version/capabilities/heartbeat; cancellation works; artifacts return with checksums; remote cannot bypass local approval or mutate local workspace silently.
### Verification plan
Future checks: SSH config validation; fake remote bootstrap protocol tests; heartbeat timeout tests; cancellation tests; artifact checksum tests; redaction tests; remote policy parity matrix.
### Deliverables/artifacts
Remote threat model, SSH profile schema, bootstrap protocol, worker lifecycle, heartbeat/cancel protocol, artifact sync, sandbox policy, remote operations guide.
### Dependencies
Phase 8 approval/shell policy, Phase 10 artifacts/events/checkpoints, Phase 19 later hardening for compliance-grade remote policy.
### Risks/conflicts
Remote credentials may leak and remote outcomes may be uncertain; mitigation is host-key pinning, scoped env allowlists, heartbeat leases, artifact checksums, and local authority.
### CLI-first/Phoenix-optional implications
CLI owns remote commands/status; optional Phoenix may render status through `Tet.*` but is not a remote control plane.
### Completion evidence
Remote bootstrap transcript, heartbeat/cancel fixture, checksum-verified artifact bundle, and remote policy parity results.
## Phase 17
### Phase intent
Self-healing and Nano Repair Mode: capture failures, queue repairs, diagnose under debugging gates, patch only with approvals, validate, hot-reload/restart safely, rollback failures, and persist lessons.
### Source anchors/citations
`/Users/adam2/projects/tet/prompt.md`; `plans/ELIXIR_CLI_AGENT_PHASED_IMPLEMENTATION.md`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/error_logging.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/_diagnostics.py`; `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/upgrades/12_durable_execution.md`; `/Users/adam2/projects/tet/source/codex-main/codex-rs/core/src/exec_policy.rs`; `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/upgrades/13_operations_and_telemetry.md`.
### Related backlog IDs/issues
`tet-db6.57` / `BD-0057`; `tet-db6.58` / `BD-0058`; `tet-db6.59` / `BD-0059`; `tet-db6.60` / `BD-0060`; `tet-db6.61` / `BD-0061`; `tet-db6.62` / `BD-0062`; `tet-db6.63` / `BD-0063`.
### Architecture decisions/ADRs
`ADR-0008` is primary; `ADR-0005` enforces diagnostic/acting gates and approvals; `ADR-0006` names Error Log, Repair Queue, Project Lessons; `ADR-0003` owns repair supervision.
### Acceptance gates
Failures create Error Log and Repair Queue records; next turn inspects open repairs; debugging tasks stay diagnostic-only; repair patches require active acting task and approval; compile/smoke pass before reload/restart; rollback keeps evidence.
### Verification plan
Future checks: failure injection; repair queue dedupe; pre-turn inspection fixture; diagnostic-only gate tests; repair approval tests; compile/smoke fixtures; hot-reload safe/unsafe decision tests; fallback repair release smoke.
### Deliverables/artifacts
Error Log schema, Repair Queue schema, trigger matrix, repair workflow, diagnostic allowlist, hot-reload decision tree, rollback protocol, checkpoint/version rule, `tet_repair` fallback release plan.
### Dependencies
Phase 10 storage/checkpoints, Phase 8 patch/approval gates, Phase 7 debugging task categories, and Phase 16 remote failure inputs.
### Risks/conflicts
Self-repair can brick the CLI if treated as magic; mitigation is checkpoints, human approval, rollback-first recovery, fallback repair binary, and full restart when hot reload is unsafe.
### CLI-first/Phoenix-optional implications
Repair is CLI/runtime-owned; Phoenix may render Error Log/Repair Queue but cannot execute repair logic or be required for recovery.
### Completion evidence
Failure injection logs, repair workflow transcript, compile/smoke verifier artifacts, hot-reload/restart event, rollback evidence, and Project Lessons entry.
## Phase 18
### Phase intent
Advanced web/remote observability: expand optional screens for sessions, tasks, artifacts, memory, Error Log, Repair Queue, approvals, and remote workers while preserving CLI parity.
### Source anchors/citations
`/Users/adam2/projects/tet/prompt.md`; `plans/ELIXIR_CLI_AGENT_PHASED_IMPLEMENTATION.md`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/api/app.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/api/websocket.py`; `/Users/adam2/projects/tet/check this plans/plan 3/plan/docs/01_architecture.md`; `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/upgrades/13_operations_and_telemetry.md`.
### Related backlog IDs/issues
`tet-db6.64` / `BD-0064`; `tet-db6.65` / `BD-0065`; `tet-db6.66` / `BD-0066`.
### Architecture decisions/ADRs
`ADR-0002` is primary; `ADR-0001` requires `Tet.*`; `ADR-0007` and `ADR-0008` define remote/repair ownership; `ADR-0006` supplies observable state names.
### Acceptance gates
Every web view has CLI/log equivalent; web uses only `Tet.*`; web can be removed; remote/repair status comes from Event Log projections; approvals still use core runtime policy.
### Verification plan
Future checks: facade-only web tests; CLI parity snapshots; subscription reconnect tests; remote/repair rendering fixtures; standalone removability regression.
### Deliverables/artifacts
Observability screen map, CLI parity matrix, event subscription model, repair/remote dashboards, access-control policy, removability regression.
### Dependencies
Phase 2 optional shell, Phase 16 remote events, Phase 17 repair events, and Phase 10 durable projections.
### Risks/conflicts
Dashboards may grow into a second control plane; mitigation is read/query APIs first, facade-only command forwarding, and dependency guards.
### CLI-first/Phoenix-optional implications
Phoenix remains optional even at advanced observability depth; CLI/log parity is non-negotiable.
### Completion evidence
Parity matrix, web facade test output, removability CI result, rendered remote/repair fixture snapshots, and CLI equivalent snapshots.
## Phase 19
### Phase intent
Security, audit, sandbox, and compliance hardening: formalize policy, secrets, redaction, audit export, sandbox boundaries, remote/MCP/repair trust, and compliance docs.
### Source anchors/citations
`/Users/adam2/projects/tet/prompt.md`; `plans/ELIXIR_CLI_AGENT_PHASED_IMPLEMENTATION.md`; `/Users/adam2/projects/tet/source/codex-main/codex-rs/core/src/exec_policy.rs`; `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/upgrades/14_secrets_and_redaction.md`; `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/upgrades/13_operations_and_telemetry.md`; `/Users/adam2/projects/tet/source/llxprt-code-main/CONTRIBUTING.md`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/plugins/shell_safety/agent_shell_safety.py`.
### Related backlog IDs/issues
`tet-db6.67` / `BD-0067`; `tet-db6.68` / `BD-0068`; `tet-db6.69` / `BD-0069`; `tet-db6.70` / `BD-0070`.
### Architecture decisions/ADRs
`ADR-0005` is primary for policy/approvals/audit; `ADR-0006` for audit/artifact storage; `ADR-0007` for remote trust; `ADR-0008` for repair approval; `ADR-0003` for runtime ownership.
### Acceptance gates
Deny beats allow; known secrets do not reach provider/log/display; audit is append-only through public APIs; shell/filesystem/remote/MCP/repair policies are tested; compliance export is redacted.
### Verification plan
Future checks: redaction property tests; secret-env guard; audit append-only/export tests; sandbox escape fuzzing; policy matrix tests; remote credential tests; MCP trust tests; compliance export fixtures.
### Deliverables/artifacts
Security policy matrix, layered redaction engine plan, secrets boundary, append-only audit schema/export, sandbox validation suite, remote hardening checklist, MCP trust policy, compliance runbook.
### Dependencies
Phases 8, 12, 16, and 17 expose the risky capabilities that Phase 19 hardens; Phase 10 provides audit/event substrate.
### Risks/conflicts
Redaction can false-positive useful data or false-negative secrets; mitigation is layered redaction, deny globs, local-provider option, explicit review, and audit sampling.
### CLI-first/Phoenix-optional implications
CLI must expose security doctor, policy, audit, and secrets checks; Phoenix may render reports but must not hold secrets or own policy.
### Completion evidence
Policy matrix test output, redaction property report, audit export artifact, sandbox fuzz summary, and compliance runbook review.
## Phase 20
### Phase intent
Packaging, documentation, migration, and release: ship standalone CLI and optional web packages, migration tooling, docs, CI, release acceptance, and rollback guidance.
### Source anchors/citations
`/Users/adam2/projects/tet/prompt.md`; `plans/ELIXIR_CLI_AGENT_PHASED_IMPLEMENTATION.md`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/config.py`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/models.json`; `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/session_storage.py`; `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/FINAL_ULTIMATE_PLAN.md`; `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/upgrades/17_phasing_and_scope.md`; `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/upgrades/19_migration_path.md`; `/Users/adam2/projects/tet/source/pi-mono-main/README.md`; `/Users/adam2/projects/tet/source/pi-mono-main/scripts/build-binaries.sh`; `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/upgrades/18_test_strategy.md`.
### Related backlog IDs/issues
`tet-db6.71` / `BD-0071`; `tet-db6.72` / `BD-0072`; `tet-db6.73` / `BD-0073`; `tet-db6.74` / `BD-0074`.
### Architecture decisions/ADRs
`ADR-0001` for standalone package; `ADR-0002` for separate optional web package; `ADR-0006` for `.tet/` migration/storage; `ADR-0008` for rollback/recovery; `ADR-0005` for release verification gates.
### Acceptance gates
Standalone package installs and runs without Phoenix; optional web package is separate; migration is dry-run-first with backups; docs cover CLI, profiles, tools, memory/state, remote, repair, security, release, and recovery.
### Verification plan
Future checks: release build; dependency closure; installer smoke; migration dry-run fixtures; docs link check; acceptance pipeline; rollback/downgrade documentation review.
### Deliverables/artifacts
Release profiles, package/installer plan, Code Puppy-settings migration spec, docs set, CLI help, CI/release pipeline, acceptance checklist, upgrade/rollback guide, support matrix.
### Dependencies
All previous phases, especially Phase 19 security hardening and Phase 1 standalone closure; release cannot paper over architectural leaks. Lipstick on a dependency graph is still a dependency graph.
### Risks/conflicts
Legacy serialized data may be unsafe to import and release bundles may bloat; mitigation is dry-run, backups, sandboxed parsing, no blind pickle execution, and size/startup budgets.
### CLI-first/Phoenix-optional implications
The final release proves the architecture: CLI package is self-sufficient, and Phoenix ships only as an optional separate artifact.
### Completion evidence
Release artifacts, installer smoke logs, migration dry-run report, docs link report, final acceptance pipeline output, and rollback guide approval.
