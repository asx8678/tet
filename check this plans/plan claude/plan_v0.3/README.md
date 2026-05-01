# Final Ultimate Tet Plan

This package is the merged result of the two uploaded plans:

- `ultimate_standalone_elixir_core_plan_gpt.zip`
- `ultimate_standalone_plan_claude.zip`

Final decision: **build Tet as a standalone Elixir/OTP runtime with a CLI-first product surface, and keep Phoenix LiveView as an optional adapter only.**

The merged plan keeps the strongest parts of both source plans and fixes the conflicts:

- Use the **Tet** namespace and `tet` CLI, not a top-level `Agent` namespace, to avoid conflict with Elixir's built-in `Agent` module.
- Use an **umbrella from day zero** so Phoenix cannot leak into core/runtime accidentally.
- Put the public `Tet` facade in **`tet_runtime`**, not `tet_core`, so `tet_core` remains pure and does not point outward to runtime.
- Use the richer Claude plan details for CLI commands, mode matrix, exit codes, data model, storage contracts, dependency guards, acceptance criteria, and risks.
- Use the GPT plan's cleaner Tet naming, `.tet/` layout, optional Phoenix boundary, and concise release profile framing.

## Files

- `FINAL_ULTIMATE_PLAN.md` — the full merged plan in one document.
- `docs/00_comparison_and_decisions.md` — side-by-side comparison and final conflict resolutions.
- `docs/01_architecture.md` — final app boundaries and dependency direction.
- `docs/02_dependency_rules_and_guards.md` — forbidden imports and CI gates.
- `docs/03_cli_commands_and_modes.md` — CLI product, modes, and exit codes.
- `docs/04_data_storage_events.md` — workspace layout, entities, events, config, storage contracts.
- `docs/05_tools_policy_approvals_verification.md` — tools, policy matrix, approval lifecycle, verifier.
- `docs/06_public_api_facade.md` — stable `Tet` facade contract.
- `docs/07_build_order_migration.md` — implementation order.
- `docs/08_release_profiles_testing_acceptance.md` — releases, tests, ship criteria.
- `docs/09_phoenix_optional_module.md` — LiveView adapter rules.
- `docs/10_risks_mitigations.md` — risk register.
- `implementation/` — concrete implementation sketches and guard scripts.
- `checklists/final_acceptance_checklist.md` — final go/no-go checklist.
- `diagrams/` — Mermaid diagrams for architecture and flows.

## One-sentence architecture

`tet_cli` and optional `tet_web_phoenix` drive the same `Tet` public API in `tet_runtime`; `tet_runtime` owns all OTP orchestration and side effects; `tet_core` owns pure domain contracts and policies; storage/provider/tool adapters hang off behaviours; Phoenix never owns Tet.
