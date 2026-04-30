# ADR-0002 — Phoenix optional and removable adapter

Status: Accepted
Date: 2026-04-30
Issue: `tet-db6.2` / `BD-0002`

## Context

Prior plans consistently allow Phoenix LiveView as a useful visualization and control surface. They also consistently warn that Phoenix must not become the application core. The architecture rule is simple enough to put on a fridge magnet:

Phoenix renders Tet. Phoenix does not own Tet.

The acceptance criteria for this issue require preserving the CLI-first/Phoenix-optional rule and resolving conflicts that would make Phoenix mandatory.

Primary sources:

- `check this plans/plan 3/plan/docs/01_architecture.md`
- `check this plans/plan 3/plan/docs/02_dependency_rules_and_guards.md`
- `check this plans/plan 3/plan/docs/09_phoenix_optional_module.md`
- `check this plans/plan claude/plan_v0.3/FINAL_ULTIMATE_PLAN.md`
- `plans/ELIXIR_CLI_AGENT_GLOBAL_VISION.md`

## Decision

Phoenix is an optional, removable adapter implemented conceptually as `tet_web_phoenix`.

Allowed dependency direction:

- `tet_web_phoenix` may depend on `tet_runtime`, `tet_core`, Phoenix, LiveView, Plug, and Cowboy.
- `tet_core`, `tet_runtime`, `tet_cli`, and store adapters must not depend on `tet_web_phoenix`, Phoenix, LiveView, Phoenix.PubSub, Plug, Cowboy, or `TetWeb.*`.
- Phoenix may subscribe to runtime events through `Tet.*` and bridge them into Phoenix PubSub/WebSocket for browsers, but Phoenix PubSub must not become the runtime event bus.

Phoenix may render:

- session timelines and transcripts;
- streamed provider text that already exists as runtime events;
- tool activity and blocked attempts;
- pending approvals and diff previews;
- verification output;
- Artifact Store, Event Log, Error Log, Repair Queue, task, profile, model, hook, remote-worker, and repair views;
- health/status routes for the web release.

Phoenix must not own:

- LLM provider calls;
- prompt composition;
- task/category/mode/path/trust policy;
- hook ordering semantics;
- approval state-machine semantics;
- patch application;
- verifier execution;
- storage schemas or direct persistence semantics;
- Universal Agent Runtime/session supervision;
- remote-worker lifecycle;
- repair execution or recovery logic.

All Phoenix actions that alter runtime state must call the same public `Tet.*` facade available to the CLI.

A removability check is mandatory for future implementation: excluding or deleting `tet_web_phoenix` must leave standalone compile, tests, and release intact.

## Conflict resolution

If a LiveView needs business logic, put that logic in core/runtime first and have LiveView call `Tet.*`. Do not copy the logic into the web layer.

If a developer wants Phoenix.PubSub because it is convenient for runtime sessions, reject it outside `tet_web_phoenix`. Runtime event fanout uses a runtime-owned bus such as Registry, `:pg`, or another configured non-web implementation.

If a feature only works when Phoenix is installed, it is not a core Tet feature. It is a web enhancement.

If adding Phoenix changes CLI behavior, storage behavior, approval semantics, or runtime supervision, Phoenix is not optional and the change violates this ADR.

## Consequences

- Optional web development happens after core runtime/facade semantics exist.
- The web release may include Phoenix dependencies; the standalone release must not.
- LiveView tests should assert facade-only calls and event-sequence parity with CLI-visible runtime state.
- Future docs should describe Phoenix screens as views over durable runtime state, not as owners of sessions.

## Review checklist

- [ ] `tet_web_phoenix` is removable without breaking standalone CLI/runtime.
- [ ] No Phoenix, Plug, Cowboy, LiveView, Phoenix.PubSub, or `TetWeb.*` reference is required outside the optional web app.
- [ ] LiveViews call `Tet.*` only for runtime state changes.
- [ ] Runtime events originate from `tet_runtime`, not Phoenix.
- [ ] CLI and Phoenix observe the same sessions, approvals, artifacts, and event sequences when Phoenix is present.
