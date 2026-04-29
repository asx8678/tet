# BD-0001 Source Inventory and Missing-Input Report

Issue: `tet-db6.1` / `BD-0001: Source inventory and missing-input report`  
Worktree: `/Users/adam2/projects/tet-db6-1`  
Branch: `feature/tet-db6-1-source-inventory`  
Base branch: `main`  
Prepared by: `code-puppy-d1d65b`  
Generated: `2026-04-29T23:15:03Z`

## 1. Scope and issue reference

This report verifies the local evidence surface that downstream architecture work must use before implementation planning starts. It covers:

- Cited repositories and local source trees.
- Prior plans and planning archives already present in the clean worktree.
- Absolute source inputs under `/Users/adam2/projects/tet`, including intentionally untracked base inputs.
- The newly merged plan deliverables in this worktree.
- `bd show tet-d1c` synthesis output and its downstream ADR guidance.
- Missing source families that must **not** be invented by later ADR work.

This is a documentation/research artifact only. It does **not** create implementation code, source files, migrations, generated project scaffolding, or runtime modules. The only intended repository artifact is this Markdown report; the later Beads comment updates `.beads/issues.jsonl` metadata.

## 2. Verification method and commands used

Commands/checks used from `/Users/adam2/projects/tet-db6-1`:

```sh
git -C /Users/adam2/projects/tet-db6-1 branch --show-current
git -C /Users/adam2/projects/tet-db6-1 status --short
find /Users/adam2/projects/tet-db6-1 -maxdepth 4 -type f | sort
bd show tet-db6.1
bd show tet-d1c
bd show tet-d1c --json
rg 'G-domain|G domain|agent-domain|agent domain|LLExpert|LL Expert|LLxprt|llxprt|llxprt-code' /Users/adam2/projects/tet
find /Users/adam2/projects/tet/source -maxdepth 2   -iname '*g*domain*' -o -iname '*agent*domain*' -o   -iname '*llexpert*' -o -iname '*ll-expert*' -o -iname '*llxprt*'
while IFS= read -r path; do test -e "$path"; done < /tmp/tet-db6-1-verified-paths.txt
```

The literal path verification set contains **155 verified local paths**, all with `test -e` result `PASS`.

Verified path count by family:

- BD metadata: 1
- Code Puppy: 45
- Codex CLI: 17
- Jido: 1
- LLxprt adjacent: 4
- Merged plans: 2
- Meta-prompt: 1
- Oh My Pi: 2
- Pi Mono: 2
- Plan 3: 11
- Prior planning: 2
- Source root: 1
- Swarm SDK/PDF: 1
- Worktree prior plans: 26
- plan_v0.3: 39

Important clean-worktree caveat from the issue context was confirmed:

| Path checked | `test -e` result | Meaning |
|---|---:|---|
| `/Users/adam2/projects/tet-db6-1/prompt.md` | FAIL | Expected: the clean worktree intentionally does not carry this untracked base input. Use `/Users/adam2/projects/tet/prompt.md`, which is verified below. |
| `/Users/adam2/projects/tet-db6-1/check this plans/swarm-sdk-architecture.pdf` | FAIL | Expected: the clean worktree intentionally does not carry this untracked base input. Use `/Users/adam2/projects/tet/check this plans/swarm-sdk-architecture.pdf`, which is verified below. |
| `/Users/adam2/projects/tet-sip` | FAIL | Stale worktree path mentioned by a merged plan as a historical command context, not a source input and not relied on here. Current synthesis review was run from `/Users/adam2/projects/tet-db6-1`. |

## 3. Verified local path inventory

Every path below was checked with `test -e` and returned `PASS`.

| # | Family | Verified local path | `test -e` | Notes |
|---:|---|---|---:|---|
| 1 | BD metadata | `/Users/adam2/projects/tet-db6-1/.beads/issues.jsonl` | PASS | Beads issue store backing `bd show` metadata/comments. |
| 2 | Merged plans | `/Users/adam2/projects/tet-db6-1/plans/ELIXIR_CLI_AGENT_GLOBAL_VISION.md` | PASS | Newly merged Global Vision plan deliverable. |
| 3 | Merged plans | `/Users/adam2/projects/tet-db6-1/plans/ELIXIR_CLI_AGENT_PHASED_IMPLEMENTATION.md` | PASS | Newly merged Phased Implementation plan deliverable. |
| 4 | Worktree prior plans | `/Users/adam2/projects/tet-db6-1/check this plans/first big plan/agent_platform_plan_final.md` | PASS | Clean-worktree prior planning artifact. |
| 5 | Worktree prior plans | `/Users/adam2/projects/tet-db6-1/check this plans/plan 3/plan/FINAL_ULTIMATE_PLAN.md` | PASS | Clean-worktree prior planning artifact. |
| 6 | Worktree prior plans | `/Users/adam2/projects/tet-db6-1/check this plans/plan 3/plan/README.md` | PASS | Clean-worktree prior planning artifact. |
| 7 | Worktree prior plans | `/Users/adam2/projects/tet-db6-1/check this plans/plan 3/plan/checklists/final_acceptance_checklist.md` | PASS | Clean-worktree prior planning artifact. |
| 8 | Worktree prior plans | `/Users/adam2/projects/tet-db6-1/check this plans/plan 3/plan/diagrams/cli_runtime_sequence.mmd` | PASS | Clean-worktree prior planning artifact. |
| 9 | Worktree prior plans | `/Users/adam2/projects/tet-db6-1/check this plans/plan 3/plan/diagrams/dependency_graph.mmd` | PASS | Clean-worktree prior planning artifact. |
| 10 | Worktree prior plans | `/Users/adam2/projects/tet-db6-1/check this plans/plan 3/plan/diagrams/phoenix_optional_sequence.mmd` | PASS | Clean-worktree prior planning artifact. |
| 11 | Worktree prior plans | `/Users/adam2/projects/tet-db6-1/check this plans/plan 3/plan/diagrams/storage_event_flow.mmd` | PASS | Clean-worktree prior planning artifact. |
| 12 | Worktree prior plans | `/Users/adam2/projects/tet-db6-1/check this plans/plan 3/plan/docs/00_comparison_and_decisions.md` | PASS | Clean-worktree prior planning artifact. |
| 13 | Worktree prior plans | `/Users/adam2/projects/tet-db6-1/check this plans/plan 3/plan/docs/01_architecture.md` | PASS | Clean-worktree prior planning artifact. |
| 14 | Worktree prior plans | `/Users/adam2/projects/tet-db6-1/check this plans/plan 3/plan/docs/02_dependency_rules_and_guards.md` | PASS | Clean-worktree prior planning artifact. |
| 15 | Worktree prior plans | `/Users/adam2/projects/tet-db6-1/check this plans/plan 3/plan/docs/03_cli_commands_and_modes.md` | PASS | Clean-worktree prior planning artifact. |
| 16 | Worktree prior plans | `/Users/adam2/projects/tet-db6-1/check this plans/plan 3/plan/docs/04_data_storage_events.md` | PASS | Clean-worktree prior planning artifact. |
| 17 | Worktree prior plans | `/Users/adam2/projects/tet-db6-1/check this plans/plan 3/plan/docs/05_tools_policy_approvals_verification.md` | PASS | Clean-worktree prior planning artifact. |
| 18 | Worktree prior plans | `/Users/adam2/projects/tet-db6-1/check this plans/plan 3/plan/docs/06_public_api_facade.md` | PASS | Clean-worktree prior planning artifact. |
| 19 | Worktree prior plans | `/Users/adam2/projects/tet-db6-1/check this plans/plan 3/plan/docs/07_build_order_migration.md` | PASS | Clean-worktree prior planning artifact. |
| 20 | Worktree prior plans | `/Users/adam2/projects/tet-db6-1/check this plans/plan 3/plan/docs/08_release_profiles_testing_acceptance.md` | PASS | Clean-worktree prior planning artifact. |
| 21 | Worktree prior plans | `/Users/adam2/projects/tet-db6-1/check this plans/plan 3/plan/docs/09_phoenix_optional_module.md` | PASS | Clean-worktree prior planning artifact. |
| 22 | Worktree prior plans | `/Users/adam2/projects/tet-db6-1/check this plans/plan 3/plan/docs/10_risks_mitigations.md` | PASS | Clean-worktree prior planning artifact. |
| 23 | Worktree prior plans | `/Users/adam2/projects/tet-db6-1/check this plans/plan 3/plan/implementation/dependency_guards.md` | PASS | Clean-worktree prior planning artifact. |
| 24 | Worktree prior plans | `/Users/adam2/projects/tet-db6-1/check this plans/plan 3/plan/implementation/mix_and_release_examples.md` | PASS | Clean-worktree prior planning artifact. |
| 25 | Worktree prior plans | `/Users/adam2/projects/tet-db6-1/check this plans/plan 3/plan/implementation/module_mapping.md` | PASS | Clean-worktree prior planning artifact. |
| 26 | Worktree prior plans | `/Users/adam2/projects/tet-db6-1/check this plans/plan 3/plan.zip` | PASS | Clean-worktree prior planning artifact. |
| 27 | Worktree prior plans | `/Users/adam2/projects/tet-db6-1/check this plans/plan claude/plan_v0.2.zip` | PASS | Clean-worktree prior planning artifact. |
| 28 | Worktree prior plans | `/Users/adam2/projects/tet-db6-1/check this plans/plan gpt/tet_improved_plan.zip` | PASS | Clean-worktree prior planning artifact. |
| 29 | Worktree prior plans | `/Users/adam2/projects/tet-db6-1/check this plans/ultimate plan/ultimate_cli_first_agent_plan.zip` | PASS | Clean-worktree prior planning artifact. |
| 30 | Meta-prompt | `/Users/adam2/projects/tet/prompt.md` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 31 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/FINAL_ULTIMATE_PLAN.md` | PASS | Absolute source anchor cited by merged plan source maps/tables. plan_v0.3 inventory file. |
| 32 | Plan 3 | `/Users/adam2/projects/tet/check this plans/plan 3/plan/docs/01_architecture.md` | PASS | Absolute source anchor cited by merged plan source maps/tables. plan 3 docs inventory file. |
| 33 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/base_agent.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 34 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/_builder.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 35 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/_runtime.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 36 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/tools/__init__.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 37 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/upgrades/11_provider_contract.md` | PASS | Absolute source anchor cited by merged plan source maps/tables. plan_v0.3 inventory file. |
| 38 | Prior planning | `/Users/adam2/projects/tet/check this plans/tet agent_platform_minimal_core.md` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 39 | Plan 3 | `/Users/adam2/projects/tet/check this plans/plan 3/plan/docs/05_tools_policy_approvals_verification.md` | PASS | Absolute source anchor cited by merged plan source maps/tables. plan 3 docs inventory file. |
| 40 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/upgrades/12_durable_execution.md` | PASS | Absolute source anchor cited by merged plan source maps/tables. plan_v0.3 inventory file. |
| 41 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/extensions/15_mcp_and_agents.md` | PASS | Absolute source anchor cited by merged plan source maps/tables. plan_v0.3 inventory file. |
| 42 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/_history.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 43 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/_compaction.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 44 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/agent_manager.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 45 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/model_factory.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 46 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/round_robin_model.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 47 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/models.json` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 48 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/config.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 49 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/mcp_/manager.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 50 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/hook_engine/engine.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 51 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/hook_engine/models.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 52 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/session_storage.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 53 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/messaging/bus.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 54 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/callbacks.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 55 | Prior planning | `/Users/adam2/projects/tet/check this plans/first big plan/agent_platform_plan_final.md` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 56 | Swarm SDK/PDF | `/Users/adam2/projects/tet/check this plans/swarm-sdk-architecture.pdf` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 57 | Codex CLI | `/Users/adam2/projects/tet/source/codex-main/codex-rs/core/src/exec_policy.rs` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 58 | Codex CLI | `/Users/adam2/projects/tet/source/codex-main/codex-rs/execpolicy/src/policy.rs` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 59 | Codex CLI | `/Users/adam2/projects/tet/source/codex-main/codex-rs/shell-command/src/command_safety/is_safe_command.rs` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 60 | Codex CLI | `/Users/adam2/projects/tet/source/codex-main/codex-rs/shell-command/src/command_safety/is_dangerous_command.rs` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 61 | Codex CLI | `/Users/adam2/projects/tet/source/codex-main/codex-rs/hooks/src/engine/dispatcher.rs` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 62 | Codex CLI | `/Users/adam2/projects/tet/source/codex-main/codex-rs/exec-server/src/protocol.rs` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 63 | Codex CLI | `/Users/adam2/projects/tet/source/codex-main/codex-rs/exec-server/src/local_process.rs` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 64 | Codex CLI | `/Users/adam2/projects/tet/source/codex-main/codex-rs/exec-server/src/server/session_registry.rs` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 65 | Codex CLI | `/Users/adam2/projects/tet/source/codex-main/codex-rs/state/migrations/0006_memories.sql` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 66 | Codex CLI | `/Users/adam2/projects/tet/source/codex-main/codex-rs/state/src/migrations.rs` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 67 | Jido | `/Users/adam2/projects/tet/source/jido-main/README.md` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 68 | LLxprt adjacent | `/Users/adam2/projects/tet/source/llxprt-code-main/docs/settings-and-profiles.md` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 69 | LLxprt adjacent | `/Users/adam2/projects/tet/source/llxprt-code-main/docs/shell-replacement.md` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 70 | Oh My Pi | `/Users/adam2/projects/tet/source/oh-my-pi-main/README.md` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 71 | Pi Mono | `/Users/adam2/projects/tet/source/pi-mono-main/README.md` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 72 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/upgrades/13_operations_and_telemetry.md` | PASS | Absolute source anchor cited by merged plan source maps/tables. plan_v0.3 inventory file. |
| 73 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/upgrades/14_secrets_and_redaction.md` | PASS | Absolute source anchor cited by merged plan source maps/tables. plan_v0.3 inventory file. |
| 74 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/upgrades/18_test_strategy.md` | PASS | Absolute source anchor cited by merged plan source maps/tables. plan_v0.3 inventory file. |
| 75 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/upgrades/19_migration_path.md` | PASS | Absolute source anchor cited by merged plan source maps/tables. plan_v0.3 inventory file. |
| 76 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/upgrades/17_phasing_and_scope.md` | PASS | Absolute source anchor cited by merged plan source maps/tables. plan_v0.3 inventory file. |
| 77 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/cli_runner.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 78 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/prompt_reviewer.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 79 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/json_agent.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 80 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/tools/file_operations.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 81 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/tools/file_modifications.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 82 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/tools/command_runner.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 83 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/plugins/shell_safety/agent_shell_safety.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 84 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/hook_engine/README.md` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 85 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/api/app.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 86 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/api/websocket.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 87 | Codex CLI | `/Users/adam2/projects/tet/source/codex-main/codex-rs/exec-server/README.md` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 88 | Codex CLI | `/Users/adam2/projects/tet/source/codex-main/codex-rs/state/migrations/0001_threads.sql` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 89 | Codex CLI | `/Users/adam2/projects/tet/source/codex-main/codex-rs/state/migrations/0014_agent_jobs.sql` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 90 | Codex CLI | `/Users/adam2/projects/tet/source/codex-main/codex-rs/thread-store/src/store.rs` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 91 | Codex CLI | `/Users/adam2/projects/tet/source/codex-main/codex-rs/memories/README.md` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 92 | Codex CLI | `/Users/adam2/projects/tet/source/codex-main/scripts/test-remote-env.sh` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 93 | LLxprt adjacent | `/Users/adam2/projects/tet/source/llxprt-code-main/README.md` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 94 | LLxprt adjacent | `/Users/adam2/projects/tet/source/llxprt-code-main/CONTRIBUTING.md` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 95 | Oh My Pi | `/Users/adam2/projects/tet/source/oh-my-pi-main/docs/custom-tools.md` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 96 | Pi Mono | `/Users/adam2/projects/tet/source/pi-mono-main/scripts/build-binaries.sh` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 97 | Source root | `/Users/adam2/projects/tet/source` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 98 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/claude_cache_client.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 99 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/tools/ask_user_question/handler.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 100 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/tools/browser/browser_screenshot.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 101 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/agent_planning.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 102 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/agent_qa_expert.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 103 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/agent_security_auditor.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 104 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/pack/shepherd.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 105 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/pack/watchdog.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 106 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/command_line/mcp/status_command.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 107 | Codex CLI | `/Users/adam2/projects/tet/source/codex-main/codex-rs/core/src/mcp_tool_call.rs` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 108 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/tools/agent_tools.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 109 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/subagent_stream_handler.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 110 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/pack/retriever.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 111 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/command_line/shell_passthrough.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 112 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/plugins/__init__.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 113 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/plugins/agent_skills/discovery.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 114 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/command_line/prompt_toolkit_completion.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 115 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/error_logging.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 116 | Code Puppy | `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/agents/_diagnostics.py` | PASS | Absolute source anchor cited by merged plan source maps/tables. |
| 117 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/README.md` | PASS | plan_v0.3 inventory file. |
| 118 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/addenda/01_architecture_addendum.md` | PASS | plan_v0.3 inventory file. |
| 119 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/addenda/07_build_order_addendum.md` | PASS | plan_v0.3 inventory file. |
| 120 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/addenda/10_risks_addendum.md` | PASS | plan_v0.3 inventory file. |
| 121 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/checklists/final_acceptance_checklist.md` | PASS | plan_v0.3 inventory file. |
| 122 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/checklists/final_acceptance_checklist_v0.3.md` | PASS | plan_v0.3 inventory file. |
| 123 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/diagrams/cli_runtime_sequence.mmd` | PASS | plan_v0.3 inventory file. |
| 124 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/diagrams/crash_recovery.mmd` | PASS | plan_v0.3 inventory file. |
| 125 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/diagrams/dependency_graph.mmd` | PASS | plan_v0.3 inventory file. |
| 126 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/diagrams/durable_workflow.mmd` | PASS | plan_v0.3 inventory file. |
| 127 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/diagrams/phoenix_optional_sequence.mmd` | PASS | plan_v0.3 inventory file. |
| 128 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/diagrams/storage_event_flow.mmd` | PASS | plan_v0.3 inventory file. |
| 129 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/diagrams/supervision_tree_v03.mmd` | PASS | plan_v0.3 inventory file. |
| 130 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/docs/00_comparison_and_decisions.md` | PASS | plan_v0.3 inventory file. |
| 131 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/docs/01_architecture.md` | PASS | plan_v0.3 inventory file. |
| 132 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/docs/02_dependency_rules_and_guards.md` | PASS | plan_v0.3 inventory file. |
| 133 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/docs/03_cli_commands_and_modes.md` | PASS | plan_v0.3 inventory file. |
| 134 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/docs/04_data_storage_events.md` | PASS | plan_v0.3 inventory file. |
| 135 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/docs/05_tools_policy_approvals_verification.md` | PASS | plan_v0.3 inventory file. |
| 136 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/docs/06_public_api_facade.md` | PASS | plan_v0.3 inventory file. |
| 137 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/docs/07_build_order_migration.md` | PASS | plan_v0.3 inventory file. |
| 138 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/docs/08_release_profiles_testing_acceptance.md` | PASS | plan_v0.3 inventory file. |
| 139 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/docs/09_phoenix_optional_module.md` | PASS | plan_v0.3 inventory file. |
| 140 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/docs/10_risks_mitigations.md` | PASS | plan_v0.3 inventory file. |
| 141 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/implementation/dependency_guards.md` | PASS | plan_v0.3 inventory file. |
| 142 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/implementation/mix_and_release_examples.md` | PASS | plan_v0.3 inventory file. |
| 143 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/implementation/module_mapping.md` | PASS | plan_v0.3 inventory file. |
| 144 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/upgrades/00_corrections.md` | PASS | plan_v0.3 inventory file. |
| 145 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/upgrades/16_cli_ergonomics.md` | PASS | plan_v0.3 inventory file. |
| 146 | plan_v0.3 | `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/upgrades/README_v03.md` | PASS | plan_v0.3 inventory file. |
| 147 | Plan 3 | `/Users/adam2/projects/tet/check this plans/plan 3/plan/docs/00_comparison_and_decisions.md` | PASS | plan 3 docs inventory file. |
| 148 | Plan 3 | `/Users/adam2/projects/tet/check this plans/plan 3/plan/docs/02_dependency_rules_and_guards.md` | PASS | plan 3 docs inventory file. |
| 149 | Plan 3 | `/Users/adam2/projects/tet/check this plans/plan 3/plan/docs/03_cli_commands_and_modes.md` | PASS | plan 3 docs inventory file. |
| 150 | Plan 3 | `/Users/adam2/projects/tet/check this plans/plan 3/plan/docs/04_data_storage_events.md` | PASS | plan 3 docs inventory file. |
| 151 | Plan 3 | `/Users/adam2/projects/tet/check this plans/plan 3/plan/docs/06_public_api_facade.md` | PASS | plan 3 docs inventory file. |
| 152 | Plan 3 | `/Users/adam2/projects/tet/check this plans/plan 3/plan/docs/07_build_order_migration.md` | PASS | plan 3 docs inventory file. |
| 153 | Plan 3 | `/Users/adam2/projects/tet/check this plans/plan 3/plan/docs/08_release_profiles_testing_acceptance.md` | PASS | plan 3 docs inventory file. |
| 154 | Plan 3 | `/Users/adam2/projects/tet/check this plans/plan 3/plan/docs/09_phoenix_optional_module.md` | PASS | plan 3 docs inventory file. |
| 155 | Plan 3 | `/Users/adam2/projects/tet/check this plans/plan 3/plan/docs/10_risks_mitigations.md` | PASS | plan 3 docs inventory file. |

## 4. Prior plan, repo, and source-family inventory

| Source family / prior plan | Local verification status | Primary verified anchors | Use for downstream ADRs |
|---|---|---|---|
| Code Puppy source tree | PRESENT under `/Users/adam2/projects/tet/source/code_puppy-main`; 45 verified anchors in the table. | `code_puppy/agents/base_agent.py`, `_builder.py`, `_runtime.py`, `_history.py`, `_compaction.py`, `agent_manager.py`, `model_factory.py`, `tools/__init__.py`, `mcp_/manager.py`, `session_storage.py`, `messaging/bus.py`, hook and plugin files. | Highest-priority behavioral reference for agents/profiles, runtime/session behavior, model routing, tools, MCP lifecycle, hooks, messaging, config, and UI/API adjacency. |
| Codex CLI materials | PRESENT under `/Users/adam2/projects/tet/source/codex-main`; 17 verified anchors in the table. | `core/src/exec_policy.rs`, `execpolicy/src/policy.rs`, shell command-safety files, hook dispatcher, exec-server files, state migrations, thread store, memories README. | Source for shell policy, approvals, hook dispatch, exec-server/remote execution patterns, state migration discipline, and safe verification defaults. |
| Swarm SDK / Swarm-style architecture | PDF PRESENT only as absolute base input; clean worktree PDF is intentionally absent. First-big-plan Markdown is present in both worktree and base source input areas. | `/Users/adam2/projects/tet/check this plans/swarm-sdk-architecture.pdf`; `/Users/adam2/projects/tet/check this plans/first big plan/agent_platform_plan_final.md`; worktree copy of first-big-plan Markdown. | Use for deterministic task discipline, category gates, priority hooks, steering, blocked-attempt capture, event capture, finding promotion, and the five invariants. Do not copy the PDF into this worktree unless a later issue truly requires it. |
| `plan_v0.3` prior plan files | PRESENT under `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3`; 39 verified files in the table. The clean worktree has only `plan_v0.2.zip`, not an extracted `plan_v0.3` directory. | `FINAL_ULTIMATE_PLAN.md`, `README.md`, docs `00`-`10`, addenda, diagrams, implementation notes, `extensions/15_mcp_and_agents.md`, upgrades `00`, `11`-`14`, `16`-`19`, `README_v03.md`, v0.3 checklist. | Use for umbrella-style boundaries, optional Phoenix, provider contracts, durable execution, operations/telemetry, secrets/redaction, MCP/agents, CLI ergonomics, phasing/scope, test strategy, and migration path. |
| Plan 3 docs | PRESENT in the clean worktree and under `/Users/adam2/projects/tet`; 11 absolute docs verified plus worktree copies. | `docs/00_comparison_and_decisions.md` through `docs/10_risks_mitigations.md`; `FINAL_ULTIMATE_PLAN.md`; README/checklist/diagrams/implementation notes in worktree. | Use for CLI-first architecture, dependency rules, commands/modes, storage/events, tools/policy/approval/verification, public facade, build order, release/testing, Phoenix optional module, and risks. |
| Newly merged plan files | PRESENT in this worktree. | `/Users/adam2/projects/tet-db6-1/plans/ELIXIR_CLI_AGENT_GLOBAL_VISION.md`; `/Users/adam2/projects/tet-db6-1/plans/ELIXIR_CLI_AGENT_PHASED_IMPLEMENTATION.md`. | Use as the current synthesized planning baseline, but keep ADR citations tied back to verified concrete local paths from this report. |
| Jido | PRESENT as adjacent source. | `/Users/adam2/projects/tet/source/jido-main/README.md`. | Inspiration only; `tet-d1c` favors custom OTP runtime first. Do not let framework adoption lead the architecture cart before the OTP horse. |
| LLxprt | PRESENT as adjacent source, not exact LLExpert. | `/Users/adam2/projects/tet/source/llxprt-code-main/README.md`, `CONTRIBUTING.md`, `docs/settings-and-profiles.md`, `docs/shell-replacement.md`. | Use only as adjacent UX/profile/shell-replacement inspiration. Do not cite it as exact LLExpert evidence. |
| Oh My Pi | PRESENT as adjacent DX source. | `/Users/adam2/projects/tet/source/oh-my-pi-main/README.md`; `docs/custom-tools.md`. | TUI/DX/plugin inspiration only, not core architecture authority. |
| Pi Mono | PRESENT as adjacent packaging/runtime source. | `/Users/adam2/projects/tet/source/pi-mono-main/README.md`; `scripts/build-binaries.sh`. | Lean monorepo/package/build inspiration only, not core architecture authority. |
| G-domain / agent-domain | **MISSING as exact local source family.** | No verified local path found. The prompt names the family, but the source tree search did not find corresponding source material. | Treat as unavailable. Use prompt requirements plus verified Code Puppy/Swarm/Codex anchors for multi-agent/orchestration claims. |
| Exact LLExpert / LL Expert | **MISSING as exact local source family.** | No verified local path found for `LLExpert`, `LL Expert`, or `ll-expert`. `llxprt-code-main` exists but is a different adjacent source. | Do not invent exact LLExpert behavior. ADRs may specify safe command correction from the prompt plus verified adjacent LLxprt/Codex shell-safety anchors. |

## 5. `bd show tet-d1c` synthesis review summary

`bd show tet-d1c` was run from `/Users/adam2/projects/tet-db6-1` and the output was reviewed. The command showed `tet-d1c` as CLOSED with eight accessible comments:

1. Initial synthesis note locking major decisions, including Owl/Tet CLI-first direction, Universal Agent Runtime profile hot-swap, Code Puppy baseline behavior, and missing-source handling. This comment text contains `[truncated]` markers in Beads output/storage.
2. Coordination note that `pack-leader-0485da` started orchestration from base `main`.
3. Failed prior execution attempt note, preserving `/Users/adam2/projects/tet-d1c` and redispatching.
4. **SYNTHESIS PART 1/3**: investigation plan and research synthesis. Key reviewed points: research/planning-only scope; no source code; source anchors for prompt, prior plans, Code Puppy, Codex, Swarm-style plan/PDF, adjacent sources; synthesis table mapping requirements into CLI-first Elixir/OTP runtime concepts; explicit missing-source handling for G-domain / agent-domain and exact LLExpert.
5. **SYNTHESIS PART 2/3**: ADR-style decisions. Reviewed accepted decisions for CLI-first core/optional Phoenix, custom OTP topology, Universal Agent Runtime hot-swap, model routing/provider strategy, tool/MCP/approval/task gates, hook system/five invariants, state/memory/recovery naming, SSH remote execution, Nano Repair Mode, safe LLExpert-style command correction, and missing-source handling.
6. **SYNTHESIS PART 3/3**: downstream guidance, acceptance checklist, risks, and verification. Reviewed guidance for the Global Vision and Phased Implementation deliverables, conflict-resolution rules, no-code/no-final-deliverable statements for `tet-d1c`, and risks including missing G-domain/agent-domain/exact LLExpert sources.
7. Shepherd critic approval after synthesis persisted.
8. Watchdog critic approval after QA.

Caveat: Beads currently presents long comment bodies with `[truncated]` markers, and the `.beads/issues.jsonl` text also stores those markers for the long comments. This report therefore reviews and summarizes the accessible persisted `bd show tet-d1c` output and does not infer hidden text. Downstream ADR work should cite the verified filesystem paths in this report plus the accessible Beads synthesis comments, not invisible fairy dust. Fairy dust is notoriously hard to unit-test.

## 6. Missing source-family report

The following source families are not available as exact, verified local source paths:

| Missing family | Verification performed | Result | Downstream handling |
|---|---|---|---|
| G-domain materials | Prompt source matrix reviewed; `rg` for `G-domain`, `G domain`, `agent-domain`, `agent domain`; `find` for path names containing `g*domain` or `agent*domain`. | No local exact source material found under `/Users/adam2/projects/tet` or `/Users/adam2/projects/tet/source`. | Do not cite unavailable internals. For orchestration/collaboration/result-merge ADRs, use the prompt requirement plus verified Code Puppy, Swarm, and Codex anchors. |
| agent-domain materials | Same as above. | No local exact source material found. | Same handling as G-domain. Explicitly say this family was unavailable if discussed in ADRs. |
| Exact LLExpert / LL Expert sources | Prompt source matrix reviewed; `rg` for `LLExpert`, `LL Expert`, `LLxprt`; `find` for `llexpert`, `ll-expert`, and `llxprt`. | No exact LLExpert local path found. `llxprt-code-main` is present and verified, but it is adjacent LLxprt material, not exact LLExpert. | Do not claim exact LLExpert evidence. Safe command correction may be specified from prompt requirements plus verified Codex shell policy and LLxprt adjacent docs. |

Also confirmed but **not** considered missing source families:

- `/Users/adam2/projects/tet/prompt.md` exists and was verified as an absolute base source path, even though the clean worktree copy is intentionally absent.
- `/Users/adam2/projects/tet/check this plans/swarm-sdk-architecture.pdf` exists and was verified as an absolute base source path, even though the clean worktree copy is intentionally absent.
- `/Users/adam2/projects/tet-sip` does not exist and is treated as a stale historical worktree path mentioned by a plan, not as a source input.

## 7. Downstream impact and guidance for `BD-0002` ADR work

`BD-0002` should proceed with these constraints:

1. Cite concrete verified paths from this report for every architectural claim. If a path is not in the verified table, run `test -e` before citing it.
2. Use the newly merged Global Vision and Phased Implementation files as the synthesized baseline, but anchor ADR evidence to the verified source paths behind them.
3. Preserve the `tet-d1c` decisions: standalone CLI-first core, Phoenix as optional adapter only, custom OTP first, Universal Agent Runtime with profile hot-swap, `ModelRouter -> ProviderAdapter -> StructuredOutputLayer`, task/tool/approval gates, deterministic hooks/five invariants, renamed state/memory terms, SSH remote execution controls, and Nano Repair Mode.
4. Treat `plan_v0.3` and Plan 3 as verified prior plans, but resolve conflicts using the prompt priority order and `tet-d1c` synthesis: Code Puppy behavior where it matters, OTP boundaries for runtime shape, safety/policy over convenience, CLI over web.
5. Explicitly acknowledge that exact G-domain / agent-domain / LLExpert sources are missing. Do not invent paths, behavior, APIs, diagrams, or provenance for those families. If exact sources appear later, create a follow-up inventory delta before changing ADR conclusions.
6. Use LLxprt only as adjacent material. The spelling is different because the source is different. Yes, this is pedantic. Good architecture is mostly useful pedantry with fewer production fires.
7. Do not copy `/Users/adam2/projects/tet/prompt.md` or the Swarm PDF into this worktree unless a later issue specifically requires vendoring/archival. Current guidance is to cite the absolute verified paths and test result.
8. Continue the no-implementation boundary until ADR acceptance is complete. BD-0002 should produce ADR documentation, not sneak in app scaffolding wearing a fake mustache.

## 8. No implementation-code statement

No implementation code, source files, project scaffolding, migrations, application modules, tests, or generated runtime artifacts were added for `tet-db6.1`. This issue produced only this documentation/report artifact. The Beads comment requested by the issue will modify issue metadata only.
