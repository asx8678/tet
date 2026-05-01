# ADR-0010: Store Callback Return Convention

**Status**: Accepted
**Accepted on 2026-04-30** by user via planning-agent-24d9f8
**Date**: 2026-04-30
**Deciders**: User approval pending; `planning-agent-24d9f8` roadmap owner; `adr-writer-340e73` author

## Context

The v0.3 storage plan makes `Tet.Store` the persistence boundary: all persistence goes through the `Tet.Store` behaviour in `tet_core`, and the canonical §04 store callbacks consistently return `{:ok, value} | {:error, term()}`. That broad error shape is the baseline for workspace, session, task, message, tool-run, approval, artifact, event, and transaction callbacks.

The v0.3 durable-execution upgrade adds workflow journal entities under the same existing `Tet.Store` behaviour. Its semantics are strong: the workflow journal is the source of truth, and side effects happen only after durable step records exist. However, its illustrative store-contract additions use narrower return tuples for journal callbacks, such as `start_step/1 :: {:ok, WorkflowStep.t()} | {:exists, WorkflowStep.t()}` and `commit_step/2 :: {:ok, WorkflowStep.t()}`, with no general adapter error branch on most callbacks.

The current `Tet.Store` behaviour implementation defines `result(value) :: {:ok, value} | {:error, error()}` and applies that broad error convention to the durable journal callbacks. `commit_step/2`, `fail_step/2`, `cancel_step/1`, `list_pending_workflows/0`, and `list_steps/1` return `result(...)`; `start_step/1` and `claim_workflow/3` keep their protocol-specific branches while also exposing a generic `{:error, error()}` failure path. This is broader than the literal §12 callback text, but aligned with §04's canonical store shape.

The decision needed is whether journal callbacks must follow §12's narrow tuples exactly, or whether §12's tuple examples should be treated as illustrative of journal semantics while §04's broader store error convention remains normative.

## Decision

`Tet.Store` callbacks will use the unified store-wide result convention: every store callback, including §12 durable workflow journal callbacks, must provide a generic `{:error, error()}` failure path in addition to its successful return. §12's literal journal callback tuples are treated as illustrative of durable-execution semantics, not as a normative prohibition on generic adapter errors; documented protocol-specific branches such as `{:exists, WorkflowStep.t()}` for idempotent step start or workflow-claim contention may remain where the journal protocol requires them.

## Consequences

**Positive**: Store adapters can surface realistic failures consistently, including SQLite locked-database errors, disk-full errors, constraint failures, Postgres/network errors, and timeouts, without using exceptions or out-of-band reporting. Callers get one broad error-handling convention across §04 and §12 callbacks, while preserving documented journal-domain outcomes such as idempotent existing steps. Store contract tests can enforce one common adapter failure shape.

**Negative**: Reviewers must know that §12's callback snippets are not exact type-signature authority for adapter failure handling. The behaviour documentation and contract tests must explicitly encode this ADR so future reviews do not misclassify the generic `{:error, error()}` branch as spec drift.

**Neutral**: The durable-execution semantics from §12 remain normative: the journal is still the source of truth, workflow steps remain idempotent, and side effects still require durable step records. This ADR only clarifies the return-contract convention. Narrowing callback returns later is caller-side reversible for code that already handles the broader shape, but adapter behaviours and shared contract tests would require a coordinated update.

## Alternatives Considered

1. Strict §12 conformance for journal callbacks — rejected because SQLite and Postgres adapters can fail for reasons §12's narrow snippets do not enumerate. Forcing those failures into exceptions or a separate reporting channel would conflict with §04's store-wide `{:ok, value} | {:error, term()}` convention and make adapter code less predictable.
2. Callback-specific or adapter-specific return shapes — rejected because it would multiply caller pattern matches and shared contract-test branches. A store seam with one general error convention is easier to implement, verify, and maintain.

## References

- v0.3 plan: `check this plans/plan claude/plan_v0.3/docs/04_data_storage_events.md` §Storage goal, lines 3-13; §Store behaviour, lines 207-239.
- v0.3 plan: `check this plans/plan claude/plan_v0.3/upgrades/12_durable_execution.md` §Why, lines 24-33; §Journal storage / Store contract additions, lines 70-108.
- Implementation evidence: `apps/tet_core/lib/tet/store.ex`, lines 50 and 155-175.
