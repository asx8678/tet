# Tet — v0.3 Engineering Plan

A standalone Elixir/OTP coding-agent product with a CLI-first
interface and an optional Phoenix LiveView. This pack is the third
revision of the engineering plan.

## What this pack is

- **Original 11 docs** (`docs/`) — the v0.1 plan, unchanged. Read these
  first if you're new.
- **Upgrades** (`upgrades/`) — additive specs that fill gaps the
  original plan left open or got wrong. v0.2 introduced these; v0.3
  fixes the bugs and scope creep that landed in v0.2.
- **Addenda** (`addenda/`) — corrections to specific original docs
  (architecture, build order, risks) that the upgrades require.
- **Extensions** (`extensions/`) — features designed for v1.x, kept
  out of v1 acceptance to avoid scope creep.
- **Implementation sketches** (`implementation/`) — unchanged from
  v0.1.
- **Diagrams** (`diagrams/`) — Mermaid sources, including v0.3
  additions for the durable workflow, recovery, and supervision tree.
- **Checklists** (`checklists/`) — the v0.3 acceptance checklist
  splits items into v1 must-have, v1 nice-to-have, and v1.x.

## Read order

If you're starting fresh:

1. `docs/00_comparison_and_decisions.md` through `docs/10` —
   the original plan in order.
2. `upgrades/README_v03.md` — this file.
3. `upgrades/17_phasing_and_scope.md` — the scope split.
4. `upgrades/00_corrections.md` — inline fixes to specific lines in
   `docs/`.
5. `upgrades/12_durable_execution.md` — the most important change.
6. `upgrades/11_provider_contract.md`, `upgrades/14_secrets_and_redaction.md`,
   `upgrades/13_operations_and_telemetry.md`, `upgrades/16_cli_ergonomics.md`.
7. `upgrades/18_test_strategy.md` — unifies the test approach.
8. `upgrades/19_migration_path.md` — only if you've already started
   building.
9. `addenda/01_architecture_addendum.md`,
   `addenda/07_build_order_addendum.md`,
   `addenda/10_risks_addendum.md`.
10. `extensions/15_mcp_and_agents.md` — if and when you reach v1.x.
11. `checklists/final_acceptance_checklist_v0.3.md` — for review.

## What changed from v0.2 → v0.3

v0.2 added six upgrade docs, and on review they had real bugs and
real scope creep. v0.3 fixes them. Mapping from issues to fixes:

| v0.2 issue                                                          | v0.3 fix                                          |
| ------------------------------------------------------------------- | ------------------------------------------------- |
| `Tet.Codec` macro used `unquote/1` at top level, won't compile      | `upgrades/00_corrections.md` §1 — explicit fns   |
| `git apply --index` as default fails when user has unrelated stage  | `upgrades/00_corrections.md` §3, doc 12 — plain `git apply` default; `--index` opt-in |
| Idempotency key hashed rolling message list, broke retry dedup      | `upgrades/12_durable_execution.md` §"Idempotency input scope" — pinned per step type |
| Recovery had no story for snapshot-exists-but-no-files-touched      | `upgrades/12_durable_execution.md` §"Crash recovery" decision tree |
| Recovery had no story for cancel-vs-crash race                      | `upgrades/12_durable_execution.md` §"Cancel-vs-crash race" |
| Multi-node 30s polling = double-execution race                      | `upgrades/13_operations_and_telemetry.md` §"Multi-node" — Postgres advisory locks; demoted to v1.x |
| "Events are projections" too strong; domain events don't fit        | `upgrades/12_durable_execution.md` §"Events: workflow projections vs. domain events" |
| `SessionWorker`'s fate unspecified after durable execution          | `addenda/01_architecture_addendum.md` — eliminated; responsibilities split |
| Tool-call normalization hand-waved                                  | `upgrades/11_provider_contract.md` §"Tool-call normalization" — actual bidirectional map for both adapters |
| `models.dev` as runtime dep                                         | `upgrades/11_provider_contract.md` — bundled JSON default; `models.dev` opt-in v1.x |
| OS keychain claimed without a maintained Elixir lib                 | `upgrades/14_secrets_and_redaction.md` — env adapter v1 default; keychain via shell-out v1.x |
| Pattern redaction overstated as sufficient                          | `upgrades/14_secrets_and_redaction.md` — explicit best-effort framing; entropy backstop |
| Placeholder redaction would corrupt files via patches               | `upgrades/14_secrets_and_redaction.md` §"The placeholder round-trip problem" — patch validator rejects |
| Shell completion shelled to `tet --json` per Tab press              | `upgrades/16_cli_ergonomics.md` §"Shell completion" — static cache file refreshed by runtime |
| Custom commands invented `{{var}}` template language                | `extensions/15_mcp_and_agents.md` §"Templating" — EEx instead |
| Bandit/Prometheus contradicted standalone-no-HTTP rule              | `upgrades/13_operations_and_telemetry.md` §"Metrics export" — `:telemetry` events; export is operator's choice |
| MCP / multi-agent / round-robin / keychain treated as v1            | `upgrades/17_phasing_and_scope.md` — explicit v1.x bucket |
| Supervision tree never updated                                      | `addenda/01_architecture_addendum.md` |
| Original risks R1–R12 not reconciled                                | `addenda/10_risks_addendum.md` |
| Build order revision sketched, not written                          | `addenda/07_build_order_addendum.md` |
| Step naming inconsistent (dots and colons)                          | `upgrades/12_durable_execution.md` §"Step naming convention" — colons only |
| Stream-stall retry of 0s amplifies overload                         | `upgrades/11_provider_contract.md` §"Retries and timeouts" — 250ms floor |
| AGENT.md mode applicability ambiguous                               | `extensions/15_mcp_and_agents.md` §"AGENT.md" — applies to all modes |
| MCP `readOnlyHint` trusted for classification                       | `extensions/15_mcp_and_agents.md` §"Read-only classification" — operator allowlist |
| Per-path trust example mixed globs and exact paths                  | `upgrades/00_corrections.md` §4 — globs only |
| Test strategy sprawled across docs without a pyramid                | `upgrades/18_test_strategy.md` — unified seven-layer pyramid |
| Migration path from v0.1 unaddressed                                | `upgrades/19_migration_path.md` — by starting state |

## Architectural constants (don't drift)

These are load-bearing decisions; changing any breaks something
elsewhere:

- **Namespace:** `Tet` (not `Agent` — collides with Elixir built-in).
- **Public facade module:** `Tet` in `apps/tet_runtime/lib/tet.ex`.
  CLIs and Phoenix call `Tet.*`, never anything else.
- **Workspace storage default:** `.tet/tet.sqlite`.
- **Modes:** `:chat` (no tools), `:explore` (read), `:execute` (write
  via approval).
- **Verifier:** allowlisted names only; never shell strings.
- **Step naming:** colons (`provider_call:attempt:1`); dots reserved
  for event types.
- **Default git apply:** working tree only; `--index` opt-in.
- **Stream-stall retry floor:** 250ms.
- **Workflow recovery for torn patches:** keyed on
  `<approval_id>/manifest.json` existence.
- **Trust:** `state` + `allow_globs` + `deny_globs` (deny wins).
- **Events:** workflow events (journal projections) and domain events
  (direct writes); both flow through `Tet.EventBus`; subscribers
  don't need to distinguish.

## What's in v1 vs v1.x

See `upgrades/17_phasing_and_scope.md` for the full split.
Quick version:

- **v1 must-have:** durable execution, provider contract with two
  adapters, atomic patches with rollback, secrets layer, redaction,
  cancellation, codec, per-path trust, telemetry, schema-version
  doctor, `--json`, property/fuzz tests for security-critical code.
- **v1 nice-to-have:** shell completion, `tet truncate`, model
  registry CLI.
- **v1.x:** MCP, multi-agent profiles, custom slash commands, live
  `models.dev`, OS keychain, multi-node, editor RPC.

## What this pack does NOT do

- Land code. This is a planning artifact. Acceptance items have
  associated tests; implementation is the team's.
- Estimate calendar time. Effort weighting in
  `upgrades/17_phasing_and_scope.md` is rough multiplicative anchors,
  not days.
- Cover product copy, marketing, or onboarding.
- Specify the LiveView UI design beyond the boundary contract — the
  Phoenix module gets one doc and is decoupled from runtime by design.

## Open questions still worth a decision

These aren't gaps — they're decisions the team should make before
implementation but that don't block the plan from being correct:

1. **SQLite vs. better single-node store.** v1 ships SQLite. If the
   journal load profile (lots of small step writes) creates real
   latency, evaluating LMDB or RocksDB as alternatives is reasonable.
2. **Default model in `priv/models.json`.** Pick a sensible default
   that works with a free-tier API key, or leave it null and require
   `tet config set model` on first run.
3. **CI runner for L5 recovery tests.** L5 needs SIGKILL semantics
   that work in the chosen CI environment; verify before committing
   to nightly.
4. **Telemetry export adapter shipping with v1.** The doc-13 default
   is JSON-log; deciding whether StatsD-over-UDP ships with v1 or
   waits is a small judgment call.

## Closing

The intent of v0.3 is to leave the plan in a state where someone
unfamiliar with the conversation can read it top-to-bottom, find no
contradictions, no scope creep, no broken examples, and a clear
boundary between v1 and v1.x. If you find any of those things, that's
a bug, not a feature.
