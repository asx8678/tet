# ADR-0003 — Custom OTP-first runtime

Status: Accepted
Date: 2026-04-30
Issue: `tet-db6.2` / `BD-0002`

## Context

The planning sources favor an Elixir/OTP-native runtime. They also mention adjacent frameworks and inspirations, including Jido-style command/data separation and Code Puppy-style agent behavior. Those sources are useful, but the system boundary cannot be delegated to a framework before Tet's own contracts are stable.

The core risk is architectural outsourcing: letting Phoenix, a third-party agent framework, MCP, or provider SDKs become the runtime source of truth. That would make the CLI-first product fragile and optional Phoenix impossible to verify.

Primary sources:

- `check this plans/plan 3/plan/docs/01_architecture.md`
- `check this plans/plan 3/plan/docs/02_dependency_rules_and_guards.md`
- `check this plans/plan claude/plan_v0.3/FINAL_ULTIMATE_PLAN.md`
- `check this plans/plan claude/plan_v0.3/upgrades/12_durable_execution.md`
- [BD-0001 source inventory and missing-input report](../research/BD-0001_SOURCE_INVENTORY_AND_MISSING_INPUT_REPORT.md)

## Decision

Tet uses a custom OTP-first runtime.

The runtime application owns supervised side effects and exposes the public `Tet.*` facade. Conceptually, the runtime includes:

- top-level application supervision;
- configuration loading;
- store supervision and adapter dispatch;
- runtime-owned event bus;
- session/workflow registry;
- workflow execution and recovery;
- provider task supervision;
- tool task supervision;
- verification task supervision;
- model/provider routing;
- prompt composition;
- patch application;
- telemetry and audit publication;
- optional remote and repair supervisors when those capabilities are enabled.

The runtime must be implemented in normal Elixir/OTP terms: supervisors, DynamicSupervisors, GenServers where appropriate, TaskSupervisors for bounded side effects, registries/process groups for lookup and event fanout, and durable store-backed recovery.

`tet_core` remains a pure library. It may define contracts and policy semantics, but it does not own process supervision or side effects.

External frameworks or systems may inspire or later adapt to Tet, but they do not lead the architecture:

- Phoenix is only an optional web adapter.
- Jido or another agent framework is inspiration or a future adapter, not the v1 runtime owner.
- Provider SDKs terminate at provider adapters.
- MCP servers are tool sources behind Tet policy, not policy owners.
- DBOS/Temporal-like durable workflow ideas may inspire the journal, but Tet owns its Elixir store contract and runtime executor.

## Conflict resolution

If a feature requires starting Phoenix to run the runtime, reject it.

If a framework wants to own sessions, state transitions, policy, approvals, or tools before Tet contracts exist, reject it or wrap it as an adapter after the custom runtime boundary is stable.

If a library requires business logic inside a provider adapter, MCP client, LiveView, or CLI command, push that logic back into core/runtime. Adapter code should translate, not govern.

If a plan suggests a top-level `Agent` namespace, reject it. `Agent` already means something in Elixir, and confusing names are a gift basket for bugs.

## Consequences

- Implementation phases must build boundary guards before piling on features.
- Runtime modules must stay cohesive; a single god-process that owns everything would violate the spirit of this ADR even if it technically uses OTP.
- Third-party framework adoption requires an explicit later decision explaining why the custom OTP contracts were insufficient.
- Runtime recovery and restart behavior must be designed around durable records, not process memory heroics.

## Review checklist

- [ ] OTP supervision is the runtime backbone.
- [ ] `tet_core` remains pure and adapter-free.
- [ ] Phoenix and third-party agent frameworks do not own runtime state or policy.
- [ ] Provider/MCP/tool frameworks terminate behind Tet behaviours and policy gates.
- [ ] Runtime process memory is reconstructable from durable records.
