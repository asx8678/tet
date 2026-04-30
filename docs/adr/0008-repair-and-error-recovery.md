# ADR-0008 — Repair and error recovery model

Status: Accepted
Date: 2026-04-30
Issue: `tet-db6.2` / `BD-0002`

## Context

The plans contain two related ideas:

1. Durable workflow/error recovery so crashes, cancellations, provider failures, verifier failures, and torn patches can be recovered safely.
2. Nano Repair Mode as a controlled self-healing workflow for diagnosing and repairing Tet itself or its workers.

Earlier v1-focused plans defer broad self-healing, while the global vision includes it as an end-state capability. This ADR resolves the conflict by separating mandatory recovery discipline from phased Nano Repair delivery.

Primary sources:

- `check this plans/plan claude/plan_v0.3/upgrades/12_durable_execution.md`
- `check this plans/plan claude/plan_v0.3/upgrades/13_operations_and_telemetry.md`
- `check this plans/plan claude/plan_v0.3/upgrades/17_phasing_and_scope.md`
- `plans/ELIXIR_CLI_AGENT_GLOBAL_VISION.md`
- `plans/ELIXIR_CLI_AGENT_PHASED_IMPLEMENTATION.md`

## Decision

Tet uses a two-layer repair and recovery model.

### Layer 1 — Durable workflow/error recovery

Durable recovery is foundational. Runtime workflows must record recoverable intent before side effects wherever the side effect needs crash recovery.

The recovery model includes:

- workflow records and workflow-step records for resumable agent turns;
- idempotency keys for steps;
- journal replay to reconstruct in-memory workflow state;
- startup recovery that scans pending workflows before accepting new work;
- cancellation as a durable workflow state, not just a killed process;
- approvals as durable workflow pauses that survive process death;
- provider retry/error classification with user-visible error events;
- verifier stdout/stderr artifacts and failure events;
- patch snapshots before writes;
- rollback manifests for create, delete, modify, rename, and mode-change cases;
- explicit `failed`, `cancelled`, `paused`, or `needs human resolution` states when recovery cannot safely continue.

A torn patch must recover to a known state. If a snapshot manifest exists, rollback runs idempotently. If a snapshot manifest does not exist, recovery treats the apply as failed before file mutation. In both cases, the outcome is recorded and visible.

Process memory is disposable. Durable records are authoritative.

### Layer 2 — Nano Repair Mode

Nano Repair Mode is a controlled repair workflow, not unsupervised self-modification.

Repair Mode may detect and capture:

- internal exceptions and supervisor crashes;
- provider adapter failures;
- tool/MCP/remote worker failures;
- compile failures and smoke failures;
- hot reload or restart failures;
- config and store migration failures;
- repeated verifier failures.

Each captured failure becomes a structured Error Log record with redacted context and artifact references. Repair Queue items are deduplicated by fingerprint and prioritized.

Repair workflow stages:

1. Detect/capture failure into Error Log.
2. Queue or update Repair Queue item.
3. Pre-turn check for critical repair blockers.
4. Diagnose under a debugging task with diagnostic/read-only tools.
5. Produce a repair plan with root cause, files/config likely affected, tests, rollback plan, and required approvals.
6. Propose repair patch/config change through the normal approval model.
7. Apply approved repair changes through normal patch/config gates.
8. Run named compile and smoke verifiers.
9. Restart or reload only when explicitly selected and safe for the state shape.
10. Checkpoint/version the validated repair.
11. Record Project Lessons or Persistent Memory only with evidence.
12. Roll back idempotently on failure.
13. Use a fallback repair binary only as an explicitly approved minimal workflow when the main CLI cannot boot.

Human approval is required for every repair write, config migration, dependency change, remote worker change, hot reload of running code, release restart, checkpoint rollback, fallback binary handoff, or secret-affecting repair.

Phoenix may render Error Log, Repair Queue, and repair approvals through `Tet.*`, but Phoenix does not execute repair logic or own recovery.

## Conflict resolution

If a plan says self-healing is not v1, that defers broad Nano Repair features; it does not remove the durable recovery requirement for core workflows.

If a plan says Nano Repair Mode exists in the end-state, it must still obey this ADR's tasks, gates, approvals, compile/smoke validation, checkpoints, rollback, and audit trail.

If an implementation tries to auto-patch Tet without human approval, reject it. The agent does not get to become a self-modifying gremlin just because the stack trace looked sad.

If hot code reload is unsafe or state shape changed, prefer supervisor subtree restart or full runtime restart from checkpoint. Hot reload is optional and approval-gated, not a default magic trick.

If Phoenix is required to recover, reject the design. Recovery belongs to runtime and fallback CLI surfaces.

## Consequences

- Store contracts must support workflow/journal/recovery concepts before risky side effects become broad.
- Patch apply must snapshot and rollback by change type; “snapshot when practical” is not enough for recovery-critical writes.
- Error Log, Repair Queue, checkpoints, Artifact Store, Event Log, and Project Lessons are reserved state concepts.
- Repair UX can be CLI-first and optionally rendered by Phoenix later.
- Reviewers should treat hidden auto-repair as a safety violation, not as a clever feature.

## Review checklist

- [ ] Durable recovery is mandatory for resumable workflows and risky side effects.
- [ ] Process memory is not authoritative after restart.
- [ ] Torn patches have snapshot/rollback recovery semantics.
- [ ] Repair writes require task gates, approvals, compile/smoke validation, checkpoints, and rollback.
- [ ] Error Log and Repair Queue are runtime/store concepts, not Phoenix concepts.
- [ ] Optional Phoenix can render repair state but cannot own repair execution.
