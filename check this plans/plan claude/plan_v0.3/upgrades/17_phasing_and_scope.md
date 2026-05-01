# 17 — Phasing and Scope

> **v0.3 introduced this doc** to fix v0.2 scope creep. v0.2 tagged
> MCP, multi-agent profiles, custom slash commands, model registry
> with live updates, round-robin keys, OS keychain integration, and
> editor RPC all as `[v0.2]` acceptance items. The v1 must-haves alone
> roughly double the original plan's effort; bundling the rest as v1
> acceptance was unrealistic and dishonest. This doc splits scope.

## Three buckets

### v1 must-have

The original plan's gaps and the architectural fixes. Without these,
the product is incomplete or unsafe.

- Durable execution (doc 12).
- Provider contract with two adapters and tool-call normalization
  (doc 11).
- Atomic patch application with per-change-type rollback (docs 12, 00).
- Secrets layer with env adapter and three redaction passes (doc 14).
- `Tet.cancel/2` on the facade and `Tet.Command.Cancel` plumbing
  (doc 00 §2, doc 12).
- `Tet.Codec` for safe atom encoding (doc 00 §1).
- Per-path trust globs (doc 00 §4).
- Telemetry events, structured log schema, audit log (doc 13).
- `tet doctor` schema-version check + `tet migrate` (doc 13).
- Property + fuzz tests for path resolver and approval state machine
  (doc 00 §5, doc 18).
- `--json` on every read command (doc 16).
- `tet help`, `tet --version`, `tet --license` (doc 16).
- `Ctrl-C` cancellation semantics in `tet chat` (doc 16).
- Single-node `tet_standalone` and single-node `tet_web` (existing
  scope).

### v1 nice-to-have

Worth shipping with v1 if there's time, but acceptable to defer.

- Shell completion (`tet completion {bash,zsh,fish}`) with cache
  file (doc 16).
- `tet truncate --keep N` (doc 16).
- Bundled model registry with `tet model list` / `show` (doc 11).
- Streaming progress spinners that hand off to streaming text
  (doc 16).
- `tet patch approve --watch` (doc 16).

### v1.x — explicitly post-v1

Real features, but not v1 acceptance criteria. Many were tagged
`[v0.2]` in the previous pack; correcting that here.

- **MCP client** (`extensions/15_mcp_and_agents.md` §"MCP").
- **Multi-agent profiles**
  (`extensions/15_mcp_and_agents.md` §"Multi-agent").
- **Custom slash commands and AGENT.md**
  (`extensions/15_mcp_and_agents.md` §"Custom slash commands").
- **Round-robin provider key rotation** (was in v0.2's doc 11; removed
  from v1; can ship as a wrapper provider in v1.x without touching
  the core behaviour).
- **Live `models.dev` integration** (doc 11; bundled JSON is v1).
- **OS keychain adapter for `Tet.Secrets`** via shell-out (doc 14).
- **Multi-node `tet_web` correctness** with Postgres advisory locks
  (doc 13).
- **`tet rpc`** JSON-RPC editor protocol (doc 16).
- **StatsD telemetry handler** (doc 13).
- **Summarization-based truncation** (`--strategy summary`, doc 16).
- **Patch summary in approval (risk classifier)** — auto-tag diffs
  by area (security/perf/style/feature) for reviewer triage.

### v2+ horizon

Mentioned in the original plan's non-goals; staying there.

Daemon/socket attach, TUI, planner/orchestrator/task graph,
specialized worker agents, remote execution, arbitrary shell tools,
package install tools, long-term memory scoring, self-healing.

## Revised build order

### Original plan + v0.3 must-haves

| Phase | Original content                                  | v0.3 additions                                        |
| ----- | ------------------------------------------------- | ----------------------------------------------------- |
| 0     | Umbrella skeleton, boundary guards                | Add `Tet.Codec`, schema-version contract              |
| 1     | Core structs, behaviours                          | Add `Tet.Workflow`, `Tet.WorkflowStep`, `Tet.Codec`   |
| 2     | Runtime foundation, public facade                 | Add `WorkflowSupervisor`, `WorkflowExecutor`, `WorkflowRecovery`. Drop `SessionWorker`. Add `Tet.cancel/2` to facade |
| 3     | Storage adapters, `.tet/` init                    | Add workflow store contract callbacks; shared contract tests |
| 4     | CLI foundation                                    | `--json` mode, help generation, version              |
| 5a    | (was 5) Chat mode foundation                      | **Now: provider contract + tool-call normalization** (doc 11) |
| 5b    | (was 5) Chat mode wiring                          | Wire chat through workflows; `compose_prompt` and `provider_call:attempt:N` steps; redaction layer 1 |
| 6     | Explore mode                                      | Per-path trust globs                                  |
| 7     | Execute mode + patches + approvals                | Atomic patch apply, per-change-type rollback, redacted-region patch validator |
| 8     | Verification loop                                 | Allowlist env scrubbing                               |
| 9     | Hardening                                         | Property + fuzz suites; recovery tests                |
| 10    | Optional Phoenix                                  | LiveView reconnect uses journal projection            |
| 11    | Release profiles                                  | `tet_standalone` closure check unchanged              |

### v0.3 new phases

| Phase | Content                                                                |
| ----- | ---------------------------------------------------------------------- |
| 12    | Operational hardening: telemetry events, log schema, doctor schema check, audit log, `tet audit export` |
| 13    | (v1.x) MCP client + multi-agent profiles + slash commands              |
| 14    | (v1.x) Multi-node `tet_web` with advisory locks                        |

Phases 12 is v1; phases 13–14 are v1.x.

## Effort weighting

Rough order-of-magnitude relative to original v1 plan:

- Original plan: 1.0×.
- + v0.3 must-haves: 1.7× (durable execution alone is ~0.4×; provider
  contract with normalization ~0.2×; atomic patch + rollback ~0.1×;
  redaction layers ~0.1×; the rest fills out).
- + v0.3 nice-to-haves: 1.85×.
- + v1.x extensions: 2.5–3×.

Treat these as planning anchors, not estimates.

## Dependencies between buckets

Some v1.x items depend on v1 must-haves and would be cheap *if and
only if* the must-haves shipped clean:

- Multi-node correctness needs the workflow journal + `claim_workflow/3`
  (already in v1's store contract as a single-node no-op).
- MCP tools fit cleanly under `Tet.Tool` only because the workflow
  journal records every tool run; otherwise crash-resume of MCP tools
  would be a separate problem.
- OS keychain shell-out is cheap because `Tet.Secrets` is a behaviour
  in v1; otherwise it would be a refactor.

This is the silver lining of the v0.3 must-have list: the v1.x
features mostly snap on rather than rewriting v1.

## Acceptance for this doc

This doc is a planning artifact; its only acceptance is consistency:

- [ ] No item appears in two buckets.
- [ ] Every `[v0.2]` tag in v0.2 docs is reclassified here as v1
      must-have, v1 nice-to-have, or v1.x.
- [ ] The build-order table in this doc agrees with `docs/07` plus
      `addenda/07_build_order_addendum.md`.
- [ ] The acceptance checklist v0.3
      (`checklists/final_acceptance_checklist_v0.3.md`) lists v1
      must-have items as required and v1 nice-to-have items as
      optional.
