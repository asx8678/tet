# ADR-0001 — Standalone CLI boundary and public facade

Status: Accepted
Date: 2026-04-30
Issue: `tet-db6.2` / `BD-0002`

## Context

The strongest prior architecture documents agree on the same spine: Tet is a local-first coding-agent runtime delivered as a standalone Elixir/OTP CLI product. Phoenix LiveView may exist later as a UI, but it is not the runtime.

The source plans also contain naming and layering conflicts that must be resolved before implementation:

- Some material uses product language such as Owl CLI while the prior Elixir boundary uses `Tet` to avoid colliding with Elixir's built-in `Agent` module.
- One prior line of thought placed a public facade in core while delegating to runtime, which would make core depend outward on runtime.
- Web UI ideas are useful, but they can accidentally drag Phoenix into the runtime if the boundary is not made painfully explicit. Painfully explicit is good here. Computers love loopholes.

Primary sources:

- `check this plans/plan 3/plan/docs/01_architecture.md`
- `check this plans/plan claude/plan_v0.3/FINAL_ULTIMATE_PLAN.md`
- `plans/ELIXIR_CLI_AGENT_GLOBAL_VISION.md`
- `plans/ELIXIR_CLI_AGENT_PHASED_IMPLEMENTATION.md`

## Decision

The standalone CLI is the default product boundary.

The internal Elixir namespace and public facade are `Tet.*`. The final executable name may be `tet`, `owl`, or both aliases later, but executable branding must not change the architecture boundary.

The public `Tet` facade lives in the runtime layer, not in core. Conceptually:

- `tet_core` owns pure domain structs, commands, events, policies, behaviours, ids, validation, and error types.
- `tet_runtime` owns the public `Tet.*` facade plus OTP supervision, sessions/workflows, providers, tools, patch application, verification, event publication, repair, and remote orchestration.
- `tet_cli` is a standalone terminal adapter. It parses arguments, streams/renders events, prompts for operator input, and exits with deterministic status codes.
- Store adapters implement persistence behind the core store behaviour.
- Optional Phoenix, TUI, remote, or repair operator surfaces call the same `Tet.*` facade.

The CLI must not:

- call provider adapters directly;
- compose prompts directly;
- enforce policy directly;
- apply patches directly;
- run shell commands or verifiers directly;
- write storage rows directly;
- call runtime internals such as workflow executors, event bus internals, tool internals, store internals, or provider internals;
- depend on Phoenix, LiveView, Plug, Cowboy, `TetWeb.*`, or a web endpoint.

The standalone release must be able to initialize/trust a workspace, start/resume sessions, send prompts, show events, display and resolve approvals, run allowlisted verification, and inspect artifacts without any web dependency in its compile-time or release-time closure.

## Conflict resolution

If a future design says Phoenix is required to run Tet, reject that design.

If a future design puts the public `Tet.*` facade in `tet_core` while it delegates to runtime, reject that design. Core must not depend on runtime.

If a future CLI implementation takes a shortcut around `Tet.*` to mutate storage, apply patches, call providers, execute tools, or run verifiers, reject that shortcut. DRY does not mean “copy business logic into the CLI because we were tired.”

If product naming conflicts reappear, use `Tet` internally until a later packaging ADR decides executable aliases. Do not use `Agent` as the root namespace.

## Consequences

- Runtime facade design is a prerequisite for CLI and optional UI work.
- CLI behavior tests should validate facade calls and deterministic exit codes instead of testing duplicated business logic.
- Release checks must prove no Phoenix/Plug/Cowboy/LiveView closure exists in standalone mode.
- Feature requests that only make sense in a browser must still be expressible through runtime state/events first, then rendered by Phoenix later if desired.

## Review checklist

- [ ] The standalone CLI can be described without mentioning Phoenix.
- [ ] All UI adapters are driving adapters that call `Tet.*`.
- [ ] `tet_core` remains pure and does not call runtime.
- [ ] The CLI has no direct provider, tool, patch, verifier, event-bus-internal, or store-internal ownership.
- [ ] Product naming does not reintroduce an `Agent` root namespace.
