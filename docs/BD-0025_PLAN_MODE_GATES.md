# BD-0025 — Plan mode gates

Status: Implemented
Date: 2025-06-01
Issue: `tet-db6.25` / `BD-0025`
Depends on: BD-0020 (read-only tool contracts)
Blocks: BD-0032

## Summary

Allow read-only research in plan mode while blocking write/edit/shell until
task commitment. Plan mode permits read-only tools (`list`, `read`, `search`,
`repo-scan`, `git-diff`, `ask-user`) in `:plan` and `:explore` modes when the
active task category is `:researching` or `:planning`. Mutating and executing
tools are blocked until the task category transitions to `:acting` and the
runtime mode transitions to `:execute` or `:repair`.

## Modules

| Module | App | Purpose |
|---|---|---|
| `Tet.PlanMode.Policy` | tet_core | Plan-mode permission policy as pure data |
| `Tet.PlanMode.Gate` | tet_core | Deterministic gate evaluation (allow/block/guide) |
| `Tet.PlanMode` | tet_core | Thin facade composing policy and gate |

## Gate decision flow

1. If no active task and policy requires one → `{:block, :no_active_task}`
2. If contract does not declare the current mode → `{:block, :mode_not_allowed}`
3. If runtime mode is plan-safe (`:plan`/`:explore`) and contract is NOT read-only → `{:block, :plan_mode_blocks_mutation}`
4. If runtime mode is plan-safe and contract IS read-only → `:allow` (with guidance)
5. If runtime mode is not plan-safe and task category is acting → `:allow`
6. Otherwise → `{:block, :category_blocks_tool}`

## Invariants enforced

1. No mutating/executing tool without an active task.
2. Category-based tool gating: researching/planning tasks are plan-safe; acting tasks unlock write/edit/shell.
3. Plan mode never widens permissions — it only narrows them.
4. Guidance emitted after plan-mode read-only tool calls.
5. Complete event capture for blocked attempts (future BD-0022/BD-0026).

## Relationship to BD-0020

BD-0020 defined read-only tool contracts with `read_only`, `mutation`, `modes`,
`task_categories`, and `execution` metadata. BD-0025 consumes those fields in
the gate; it does not re-define tool capabilities. The six BD-0020 contracts
all declare `:plan` in their `modes` list and `:researching`/`:planning` in
their `task_categories`, so they pass the gate in plan mode.

## CLI-first / Phoenix-optional

All gate modules live in `tet_core` with zero side effects. No GenServer, no
filesystem access, no shell calls, no Phoenix dependency. The gate is a set of
pure functions that can be called from CLI, runtime, or future Phoenix adapters.

## Future work

- BD-0024: HookManager will run hooks after gate passes.
- BD-0026: Five invariants test suite will verify event capture.
- BD-0027: Approval and diff artifact model for mutating tools.
- BD-0028+: Mutating tool contracts (`:execute`/`:repair` modes) will not
  declare `:plan` in their modes, so they will be blocked by the gate
  automatically.
