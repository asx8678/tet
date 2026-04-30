# Architecture Decision Records

This directory is the Architecture Decision Record (ADR) set for `tet-db6.2` / `BD-0002: ADR set for CLI-first boundaries`.

The ADRs are planning documentation only. They reserve boundaries, names, and conflict-resolution rules for future implementation phases; they do not add application source, migrations, release files, or executable code. No sneaky implementation gremlins live here. 🐶

## ADR convention used here

The repository did not have an existing ADR directory or template before this issue. This set therefore uses a deliberately small convention:

- File names are `NNNN-short-title.md`.
- Each ADR has `Status`, `Date`, `Issue`, `Context`, `Decision`, `Conflict resolution`, `Consequences`, and `Review checklist` sections.
- `Accepted` means accepted for downstream planning and implementation unless a later ADR supersedes it.
- Source references are cited as local paths or already-verified absolute source anchors. Unavailable source families must stay marked unavailable instead of being hand-waved into existence by architectural jazz hands.

## Primary sources reviewed

- [BD-0001 source inventory and missing-input report](../research/BD-0001_SOURCE_INVENTORY_AND_MISSING_INPUT_REPORT.md)
- `check this plans/plan 3/plan/docs/01_architecture.md`
- `check this plans/plan 3/plan/docs/02_dependency_rules_and_guards.md`
- `check this plans/plan 3/plan/docs/04_data_storage_events.md`
- `check this plans/plan 3/plan/docs/05_tools_policy_approvals_verification.md`
- `check this plans/plan 3/plan/docs/09_phoenix_optional_module.md`
- `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/FINAL_ULTIMATE_PLAN.md`
- `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/upgrades/12_durable_execution.md`
- `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/upgrades/13_operations_and_telemetry.md`
- `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/upgrades/17_phasing_and_scope.md`
- `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/extensions/15_mcp_and_agents.md`
- `plans/ELIXIR_CLI_AGENT_GLOBAL_VISION.md`
- `plans/ELIXIR_CLI_AGENT_PHASED_IMPLEMENTATION.md`

## Non-negotiable rule stack

These rules intentionally repeat across the ADRs because boundary drift is how nice architectures become soup:

1. The standalone CLI is the default product and must work end to end without Phoenix, LiveView, Plug, Cowboy, or a web endpoint.
2. Phoenix is optional and removable. It may render and control through the public facade, but it must never own runtime state, policy, providers, tools, storage, approvals, verification, remote execution, or repair.
3. Elixir/OTP runtime services own side effects. Core owns pure contracts and policy semantics. UI adapters parse intent and render output.
4. CLI, Phoenix, TUI, remote operators, and repair operators use the public `Tet.*` facade. They do not call runtime internals or store internals directly.
5. Every mutating or executing action goes through task/category gates, hooks, deterministic policy, approvals where required, supervised execution, durable artifacts, and Event Log capture.
6. Durable records beat process memory. A restarted runtime must reconstruct from the store, journal, Event Log, artifacts, and checkpoints.

When a future plan, ticket, or implementation convenience conflicts with this stack, the stack wins. Yes, even if the convenience looks very shiny.

## ADR index and mandatory coverage

| ADR | Status | Mandatory coverage |
|---|---|---|
| [ADR-0001 — Standalone CLI boundary and public facade](0001-standalone-cli-boundary.md) | Accepted | Standalone CLI boundary, `Tet.*` facade, CLI-first release rule |
| [ADR-0002 — Phoenix optional and removable adapter](0002-phoenix-optional-adapter.md) | Accepted | Phoenix optionality, removability, facade-only UI |
| [ADR-0003 — Custom OTP-first runtime](0003-custom-otp-first-runtime.md) | Accepted | Custom OTP first, runtime supervision, framework conflict resolution |
| [ADR-0004 — Universal Agent Runtime boundary](0004-universal-agent-runtime-boundary.md) | Accepted | Universal Agent Runtime, profile hot-swap, durable state boundary |
| [ADR-0005 — Gates, approvals, and verification](0005-gates-approvals-verification.md) | Accepted | Task gates, hooks, policy, approvals, verifier allowlist |
| [ADR-0006 — Storage names and boundaries](0006-storage-names-and-boundaries.md) | Accepted | Storage naming, `.tet/`, store adapters, state terms |
| [ADR-0007 — Remote execution boundary](0007-remote-execution-boundary.md) | Accepted | SSH remote execution model, local control plane, result merge |
| [ADR-0008 — Repair and error recovery model](0008-repair-and-error-recovery.md) | Accepted | Durable recovery, Error Log, Repair Queue, Nano Repair Mode |

## BD-0002 acceptance checklist

| Acceptance requirement | Covered by | Review check |
|---|---|---|
| Standalone CLI boundary is explicit | ADR-0001 | CLI is a driving adapter and standalone release is default |
| Phoenix optionality/removability is explicit | ADR-0002 | `tet_web_phoenix` can be removed without breaking standalone CLI/runtime |
| Custom OTP-first runtime is explicit | ADR-0003 | OTP supervision/runtime owns side effects, not Phoenix or a framework |
| Universal Agent Runtime boundary is explicit | ADR-0004 | UAR owns turn orchestration while durable records remain authoritative |
| Gate/approval model is explicit | ADR-0005 | No mutating/executing action bypasses task, hook, policy, approval, event capture |
| Storage naming and boundaries are explicit | ADR-0006 | `Tet`, `.tet/`, `tet_store_*`, Event Log, Artifact Store, Error Log, Repair Queue are reserved |
| Remote execution model is explicit | ADR-0007 | SSH workers are less-trusted targets controlled by local runtime |
| Repair/error recovery model is explicit | ADR-0008 | Durable workflow recovery and Nano Repair Mode are gated and auditable |
| Conflicts are resolved | This README plus each ADR | CLI-first/Phoenix-optional rule wins in every conflict |
| No implementation code present | Git diff review | Only Markdown documentation under `docs/adr/` is added |

## Conflict-resolution matrix

| Conflict | Resolution | ADRs |
|---|---|---|
| Web-first or Phoenix-owned runtime vs standalone CLI | Standalone CLI/runtime is the product core; Phoenix is a removable adapter | ADR-0001, ADR-0002 |
| Public facade in `tet_core` vs `tet_runtime` | `Tet.*` facade lives in `tet_runtime`; `tet_core` stays pure and runtime-free | ADR-0001, ADR-0003 |
| `Agent` namespace / `.agent/` naming vs Elixir collision | Use internal namespace `Tet` and workspace directory `.tet/`; product executable alias can be decided later | ADR-0001, ADR-0006 |
| External agent framework or Phoenix lifecycle vs custom OTP | Custom OTP runtime is first; frameworks may become adapters only after contracts prove the need | ADR-0003, ADR-0004 |
| Long-lived Universal Agent Runtime vs durable workflow journal | UAR is the session orchestration boundary; durable store/journal/Event Log are authoritative after restart | ADR-0004, ADR-0008 |
| Remote/repair as end-state features vs not initial CLI scope | Boundaries are accepted now; delivery can be phased, and neither feature may bypass CLI-first gates | ADR-0007, ADR-0008 |
| Arbitrary shell/tool convenience vs policy safety | Named verifiers and approved/gated actions only; deterministic policy beats model advice | ADR-0005 |
| Vague embedded storage vs explicit adapters | Use `tet_store_memory`, `tet_store_sqlite`, optional `tet_store_postgres`, all behind `Tet.Store` | ADR-0006 |

## Reviewer checklist

- [ ] All eight ADR files are present and linked from this README.
- [ ] All eight ADRs are `Accepted` and reference `BD-0002` / `tet-db6.2`.
- [ ] The CLI-first/Phoenix-optional rule is present in the README and not contradicted by any ADR.
- [ ] Remote and repair are constrained as runtime-controlled, gated capabilities rather than web-owned or model-owned shortcuts.
- [ ] Storage names use `Tet`, `.tet/`, `tet_store_*`, Event Log, Session Memory, Task Memory, Artifact Store, Error Log, Repair Queue, Project Lessons, and checkpoints.
- [ ] No implementation source, migrations, build configuration, or release configuration is added by this issue.
