# ADR-0005 — Gates, approvals, and verification

Status: Accepted
Date: 2026-04-30
Issue: `tet-db6.2` / `BD-0002`

## Context

The source plans converge on a safety model where model output is not authority. Tool intents are proposals. Writes and execution are gated by deterministic policy, task state, and user approvals.

This ADR turns that into a boundary rule so future implementation does not invent six almost-identical policy systems in CLI, Phoenix, tools, remote workers, and repair. Six policy systems is not “flexible”; it is just a bug farm with branding.

Primary sources:

- `check this plans/plan 3/plan/docs/05_tools_policy_approvals_verification.md`
- `check this plans/plan 3/plan/docs/02_dependency_rules_and_guards.md`
- `plans/ELIXIR_CLI_AGENT_GLOBAL_VISION.md`
- `plans/ELIXIR_CLI_AGENT_PHASED_IMPLEMENTATION.md`
- `check this plans/plan claude/plan_v0.3/extensions/15_mcp_and_agents.md`

## Decision

Every tool, write, execution, remote, MCP, repair, config, or secret-affecting intent goes through one runtime-owned gate pipeline.

The conceptual gate order is:

1. Resolve workspace, session, active task, profile, and trust state.
2. Enforce task existence for mutating/executing actions.
3. Enforce task category gates such as researching, planning, acting, verifying, debugging, and documenting.
4. Enforce mode gates such as chat, plan, explore, execute, and repair.
5. Enforce profile/tool manifest allowlists.
6. Run priority-ordered hooks.
7. Run deterministic policy for path boundaries, symlinks, file sizes, patch sizes, command allowlists, secrets, sandbox, remote scope, and pending approvals.
8. Convert risky proposals into durable approval requests when required.
9. Execute only after policy and approvals allow it, using supervised runtime executors.
10. Persist tool runs, artifacts, events, audit entries, verifier output, and blocked attempts.
11. Emit guidance after task operations and verification results.

The five cross-phase invariants are accepted:

1. No mutating or executing tool without an active task.
2. Category-based tool gating.
3. Priority-ordered hook execution.
4. Guidance after task operations.
5. Complete event capture, including blocked attempts.

Approval semantics:

- approval statuses are `pending`, `approved`, and `rejected`;
- approval is not execution;
- patch application, remote execution, repair action, verifier execution, and rollback are separate runtime actions/events;
- only one pending approval may block a session/workflow at a time unless a later ADR explicitly changes this;
- rejected approvals mutate nothing;
- approved patches must still apply cleanly and pass current policy before writing.

Verification semantics:

- normal verifier execution uses named allowlist entries, not raw shell strings;
- verifier commands run with scrubbed environment, timeout, workspace working directory, stdout/stderr artifacts, redaction, and events;
- arbitrary shell is out of the normal path and would require an explicit later decision, task, policy, and approval model.

Deterministic policy runs before LLM steering. LLM review may suggest focusing, guiding, or blocking, but it cannot widen permissions.

## Conflict resolution

If model output says a tool is safe but deterministic policy blocks it, policy wins.

If a CLI or Phoenix screen wants to “just approve and apply” in one local shortcut, reject it. Approval and execution remain separate durable steps.

If an MCP server claims a tool is read-only, do not trust that claim automatically. Operator allowlist and Tet policy decide classification.

If a remote worker, repair profile, or provider adapter wants to execute outside the gate pipeline, reject it. There are not two safety systems. There is one.

## Consequences

- Core policy semantics must be reusable by runtime services and testable without UI dependencies.
- Runtime must persist blocked attempts, not silently ignore them.
- Approval UX can exist in CLI or Phoenix, but both operate over the same approval rows/events through `Tet.*`.
- Tool manifests need capability metadata so policy can reason about read/write/execute/remote/repair behavior.

## Review checklist

- [ ] Mutating/executing actions require active task and category-appropriate gate.
- [ ] Approval and execution are distinct durable operations.
- [ ] Verifiers are named allowlist entries, not raw shell strings.
- [ ] Blocked attempts are persisted with reason metadata.
- [ ] MCP, remote, and repair actions do not bypass the same gate pipeline.
