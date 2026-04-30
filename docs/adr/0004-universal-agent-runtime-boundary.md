# ADR-0004 — Universal Agent Runtime boundary

Status: Accepted
Date: 2026-04-30
Issue: `tet-db6.2` / `BD-0002`

## Context

The broader product vision calls for a Universal Agent Runtime that can preserve session history, attachments, task state, artifacts, approvals, and provider cache hints while switching between profiles such as planner, coder, reviewer, tester, remote-runner, and repair.

The v0.3 durable execution plan also corrects an earlier in-memory session model: workflow state must be journaled and recoverable, with the journal/store as source of truth. That creates an apparent conflict with “one long-lived runtime per session.” The conflict is fake if the boundary is named correctly; it is very real if somebody treats a GenServer heap as sacred. Spoiler: it is not sacred.

Primary sources:

- `plans/ELIXIR_CLI_AGENT_GLOBAL_VISION.md`
- `plans/ELIXIR_CLI_AGENT_PHASED_IMPLEMENTATION.md`
- `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/upgrades/12_durable_execution.md`
- `/Users/adam2/projects/tet/check this plans/plan claude/plan_v0.3/extensions/15_mcp_and_agents.md`
- [BD-0001 source inventory and missing-input report](../research/BD-0001_SOURCE_INVENTORY_AND_MISSING_INPUT_REPORT.md)

## Decision

Universal Agent Runtime is the session orchestration boundary, not an in-memory source of truth.

A Universal Agent Runtime owns the turn-level coordination for a session or active workflow:

- load session, task, profile, prompt, artifact, approval, and checkpoint references;
- compose prompts through runtime services;
- route model requests through the model router;
- normalize provider tool intents;
- send every tool intent through gates and approvals;
- record events, artifacts, workflow steps, and audit entries;
- handle cancellation and profile swaps at safe boundaries;
- rehydrate from durable state after restart.

Profiles are data, not runtime subclasses. A profile may define identity, prompt layers, default mode, allowed modes, task category defaults, tool allowlist, MCP allowlist, remote allowlist, policy overlays, hook overlays, model pin, provider preferences, structured output expectations, verifier posture, compaction settings, artifact visibility, repair capabilities, and migration metadata.

Profile hot-swap is accepted with these constraints:

- swaps happen at turn boundaries by default;
- active provider streams, running tools, running remote jobs, and pending approvals cannot be unsafely mutated mid-flight;
- interrupting or forking requires a checkpoint;
- pending approvals remain attached to the original session/workflow and must be revalidated before apply;
- capability changes cannot widen deterministic gates without policy and, where required, user approval;
- tool declarations, MCP exposure, provider cache hints, prompt fingerprints, and structured-output expectations are invalidated when compatibility cannot be proven;
- swap outcomes are durable events.

An implementation may use a GenServer per session, a workflow executor per active workflow, or a hybrid, but the external contract is the same: durable records are authoritative and the runtime can recover without trusting process heap state.

## Conflict resolution

Code Puppy-style named agents map to data profiles over one Universal Agent Runtime boundary. They do not require a hardcoded zoo of separate runtime classes.

Jido-style or other framework orchestration can inform design, but custom OTP remains the owner of lifecycle and recovery.

If a future implementation says “the profile state only exists in memory,” reject it. Session Memory, Task Memory, Event Log, artifacts, approvals, checkpoints, and workflow steps must persist.

If a profile tries to add executable code or bypass tools/policy, reject it. Profiles can restrict and configure capabilities; they do not smuggle new runtime code into the system.

## Consequences

- Profile hot-swap needs compatibility checks, durable events, and checkpoint semantics.
- Provider cache preservation must be opportunistic, not promised. If compatibility is uncertain, discard cache hints and pay the token cost like a responsible adult.
- Subagents and specialized workers must run as bounded tasks/sub-sessions under the same Event Log and task model.
- Optional Phoenix may render profile state and initiate swaps through `Tet.*`, but it does not own profile semantics.

## Review checklist

- [ ] UAR is described as orchestration, not authoritative process memory.
- [ ] Profiles are data and cannot bypass tool/policy gates.
- [ ] Profile swaps preserve durable session/task/artifact/approval state or checkpoint/fork explicitly.
- [ ] Cache hints are invalidated when compatibility cannot be proven.
- [ ] Optional UI adapters initiate UAR operations only through `Tet.*`.
