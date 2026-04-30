# BD-0007 — Optional `tet_web_phoenix` adapter facade contract

Status: Accepted planning contract
Date: 2026-04-30
Issue: `tet-db6.7` / `BD-0007`

## Purpose

This document defines the contract for a future optional Phoenix adapter named
`tet_web_phoenix`.

This issue deliberately does **not** add Phoenix, LiveView, Plug, Cowboy, a web
endpoint, router, release, Ecto repo, migration, or generated Phoenix app. The
contract exists so that a later web implementation has a narrow adapter seam
instead of becoming a second runtime wearing a browser hat. Browser hats are
cute; duplicated policy engines are not.

## Source anchors inspected

- `check this plans/plan 3/plan/docs/01_architecture.md`
- `check this plans/plan 3/plan/docs/02_dependency_rules_and_guards.md`
- `check this plans/plan 3/plan/docs/09_phoenix_optional_module.md`
- `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/api/app.py`

The Code Puppy FastAPI source is useful as a reminder that web adapters often
own request lifecycle, middleware, HTTP routes, and WebSocket plumbing. Tet keeps
that adapter lifecycle separate from agent/runtime ownership: Phoenix may own
Phoenix things; it does not own Tet things.

## Contract summary

`tet_web_phoenix` is an optional driving adapter.

It may parse browser intent, maintain browser-only presentation state, and
render runtime/core data. It may call the public `Tet` facade to ask the runtime
to do work. It must not implement, duplicate, bypass, or supervise Tet business
logic.

```text
Browser / LiveView event
        │
        ▼
tet_web_phoenix parses intent and renders output
        │ calls public facade only
        ▼
Tet.* facade in tet_runtime
        │ owns side effects
        ▼
tet_runtime + tet_core + configured adapters
```

The facade is the same seam used by `tet_cli`. If an operation cannot be
expressed through the public `Tet` facade, the correct fix is to add or extend a
runtime facade function, not to tunnel into runtime internals from a LiveView.
Sneaky tunnels are how architecture gets termites.

## Allowed ownership in `tet_web_phoenix`

The optional web adapter may own browser and Phoenix integration concerns:

- Phoenix endpoint, router, controllers, channels, LiveViews, components, and
  templates for the web release;
- web request lifecycle, browser sessions, cookies, CSRF, CORS, timeout handling,
  and static assets;
- presentation-only assigns and UI state such as selected tabs, expanded rows,
  filters, sort order, modal visibility, and optimistic render hints;
- browser-specific event fanout, including bridging runtime events into Phoenix
  PubSub or WebSockets for connected browsers;
- health/status routes for the optional web release;
- view models that translate runtime/core data into HTML-friendly shapes without
  changing Tet state or policy.

Presentation-only state must be disposable. Restarting Phoenix must not lose Tet
session state, approvals, task progress, provider state, artifacts, repair state,
or durable events.

## Required call boundary

Runtime-affecting actions in `tet_web_phoenix` must call the public `Tet` facade
only.

Current and future facade examples include calls shaped like:

```elixir
Tet.doctor(opts)
Tet.start_session(workspace_ref, opts)
Tet.send_prompt(session_id, prompt, opts)
Tet.ask(prompt, opts)
Tet.list_messages(session_id, opts)
Tet.list_events(session_id, opts)
Tet.subscribe_events()
Tet.subscribe_events(session_id)
# Future examples:
# Tet.approve_patch(approval_id, opts)
# Tet.reject_patch(approval_id, opts)
# Tet.run_verifier(session_id, verifier_name, opts)
# Tet.cancel_workflow(workflow_id, opts)
```

The web adapter may pattern-match or render core data contracts such as
`%Tet.Event{}`, `%Tet.Message{}`, `%Tet.Session{}`, `%Tet.Task{}`,
`%Tet.ToolRun{}`, `%Tet.Approval{}`, and `%Tet.Artifact{}` when those contracts
exist. Rendering a struct is not permission to own its state machine.

## Explicitly forbidden ownership

No module under `tet_web_phoenix` may own or duplicate:

- task, category, mode, trust, path, command, hook, secret, sandbox, remote, or
  verifier policy;
- Universal Agent Runtime/session state machines;
- approval state-machine semantics, approval persistence, or apply-after-approve
  shortcuts;
- LLM provider selection, provider adapters, streaming protocol parsing, prompt
  composition, model routing, provider cache semantics, or provider credentials;
- tool manifests, tool execution, MCP execution, shell execution, verifier
  execution, patch application, rollback, or artifact writes;
- store schema ownership, direct persistence semantics, migrations, repos, or
  direct calls into store adapters;
- Event Log, Error Log, Repair Queue, Artifact Store, Session Memory, Task
  Memory, checkpoints, or durable workflow journal ownership;
- repair execution, Nano Repair Mode, recovery decisions, or remote-worker
  lifecycle;
- Tet runtime supervision, session supervisors, provider/task/verifier
  supervisors, or runtime event bus ownership.

A web screen may show a pending approval. It may not decide what approval means.
A web screen may show a verifier result. It may not run arbitrary shell to make
one. A web screen may show provider text. It may not become a provider adapter.
Very glamorous, very illegal.

## Forbidden direct calls and references

`tet_web_phoenix` source must not call or alias internal Tet modules such as:

```text
Tet.Application
Tet.Runtime.*
Tet.EventBus.*
Tet.Agent.Runtime.*
Tet.Prompt.*
Tet.Policy.*
Tet.Patch.*
Tet.Provider.*
Tet.Tool.*
Tet.Tools.*
Tet.Store.*
Tet.Store.SQLite.*
Tet.CLI.*
```

The rule is intentionally stricter than “do not mutate state directly.” Even
read-only calls into internals create coupling and make Phoenix harder to remove.
If the web adapter needs data, expose it through `Tet.*` facade functions backed
by runtime/core contracts.

## Dependency contract

Allowed direction:

```text
tet_web_phoenix -> tet_runtime -> tet_core
tet_web_phoenix -> tet_core for rendering pure data contracts
tet_web_phoenix -> phoenix/liveview/plug/cowboy in the optional web release only
```

Forbidden direction:

```text
tet_core          -> tet_web_phoenix | Phoenix | Plug | Cowboy | LiveView
tet_runtime       -> tet_web_phoenix | Phoenix | Plug | Cowboy | LiveView
tet_cli           -> tet_web_phoenix | Phoenix | Plug | Cowboy | LiveView
tet_store_*       -> tet_web_phoenix | Phoenix | Plug | Cowboy | LiveView
tet_provider_*    -> tet_web_phoenix | Phoenix | Plug | Cowboy | LiveView
```

`tet_web_phoenix` must not depend directly on `tet_cli`, `tet_store_*`, or
`tet_provider_*` applications. Store and provider selection belong behind the
runtime/core contracts, not behind a web page with opinions.

`tet_web_phoenix` must not introduce Ecto/SQLite/Postgres ownership for Tet
state. If a web release uses a store, it selects an existing Tet store adapter
through runtime configuration; it does not create web-owned Tet schemas.

## Event and subscription contract

Runtime events originate from `tet_runtime` and durable records, not from
Phoenix PubSub.

A future web adapter may subscribe through facade functions such as
`Tet.subscribe_events/0` or `Tet.subscribe_events/1`, then bridge those events to
connected browsers. Phoenix PubSub may be a browser delivery mechanism inside
the optional web app; it must not replace `Tet.EventBus` or become the
authoritative runtime bus.

CLI-created sessions and web-rendered sessions must observe the same durable
messages, approvals, artifacts, and event sequence.

## Approval and verification contract

Approvals and verification follow ADR-0005:

1. proposal/intention is captured by runtime;
2. deterministic policy decides whether approval is required;
3. approval or rejection is recorded durably;
4. execution/apply/verifier actions happen as separate runtime operations;
5. events and artifacts are persisted.

`tet_web_phoenix` may render the pending approval and send approve/reject intent
through `Tet.*`. It must not combine “approve” and “apply” as a local LiveView
shortcut, and it must not run raw verifier commands.

## Runtime supervision contract

A Phoenix application may supervise Phoenix infrastructure: endpoint, PubSub for
browser fanout, Telemetry, static asset watchers in development, and similar web
processes.

It must not supervise Tet session workers, provider tasks, tool tasks, verifier
tasks, repair tasks, store processes, runtime registries, or the runtime event
bus. Those remain under `tet_runtime` or configured Tet adapter applications.

## Valid LiveView shape

A valid LiveView stays shallow:

```text
mount/3
  -> Tet.start_session/2 or Tet.list_events/2 or Tet.list_messages/2
  -> assign presentation state

handle_event("send_prompt", params, socket)
  -> parse browser params
  -> Tet.send_prompt(session_id, prompt, opts)
  -> update presentation state from returned facade result

handle_event("approve", params, socket)
  -> Tet.approve_patch(approval_id, opts)

handle_info(%Tet.Event{} = event, socket)
  -> append/render event
```

Invalid LiveViews call `Tet.Runtime.*`, call provider modules, run shell
commands, apply patches, mutate stores, or implement their own approval machine.
That is not “pragmatic”; that is a second product pretending to be a component.

## ADR traceability

This contract specializes the accepted ADR stack:

| ADR | Contract tie |
|---|---|
| [ADR-0001 — Standalone CLI boundary and public facade](adr/0001-standalone-cli-boundary.md) | `tet_cli` and `tet_web_phoenix` use the same public `Tet` facade; adapter branding does not move business logic. |
| [ADR-0002 — Phoenix optional and removable adapter](adr/0002-phoenix-optional-adapter.md) | Phoenix is optional, removable, and facade-only. Removing it must not break standalone CLI/runtime. |
| [ADR-0003 — Custom OTP-first runtime](adr/0003-custom-otp-first-runtime.md) | OTP runtime owns side effects, supervision, providers, tools, stores, and runtime events. Phoenix does not. |
| [ADR-0004 — Universal Agent Runtime boundary](adr/0004-universal-agent-runtime-boundary.md) | Session/profile/workflow state is durable runtime state, not LiveView assigns or browser memory. |
| [ADR-0005 — Gates, approvals, and verification](adr/0005-gates-approvals-verification.md) | Web approval and verifier UX must go through the same gate pipeline as CLI. |

## Guard tooling

`tools/check_web_facade_contract.sh` is a standalone-safe source guard. It does
not compile Phoenix and does not require Phoenix dependencies. It currently:

- exits successfully when `apps/tet_web_phoenix` is absent;
- checks future web source for direct references to known forbidden Tet internals;
- allows root facade calls such as `Tet.send_prompt(...)`;
- allows rendering-oriented references to core data structs listed in the guard;
- rejects obvious domain-owner namespaces/directories under the web app;
- rejects direct web dependencies on `tet_cli`, `tet_store_*`, `tet_provider_*`,
  or web-owned Tet storage dependencies such as Ecto/Postgres/SQLite libraries;
- checks existing non-web umbrella apps for direct web framework dependencies.

Run it directly:

```bash
tools/check_web_facade_contract.sh
```

or through Mix:

```bash
mix web.facade_contract
```

The guard is intentionally lightweight and conservative. A future compiled xref
check can replace or extend it once `tet_web_phoenix` exists. The cheap source
guard still earns its kibble by catching the obvious foot-guns before CI spends
minutes compiling a web app it should not need.

## Future BD-0009 removability gate

BD-0009 should add a stronger removability gate for the actual web adapter. The
gate should prove that deleting or excluding `apps/tet_web_phoenix` still allows:

```bash
mix compile --warnings-as-errors
mix test
MIX_ENV=prod mix release tet_standalone --overwrite
tools/check_release_closure.sh --no-build
tools/check_web_facade_contract.sh
```

The BD-0009 gate should also add a compiled xref/facade-only check for the web
app when Phoenix exists. Expected failure classes:

- any non-web app depends on `tet_web_phoenix` or web frameworks;
- standalone release closure contains Phoenix/Plug/Cowboy/websocket server libs;
- web source calls internal runtime/store/provider/tool/policy modules;
- removing the web adapter changes CLI behavior, runtime supervision, store
  behavior, approval semantics, or verifier behavior.

Until BD-0009 lands, this document plus the source guard is the contract of
record.

## Review checklist

- [ ] No Phoenix dependency is added by this contract issue.
- [ ] `tet_web_phoenix` is described as optional and removable.
- [ ] Web runtime-affecting actions call the public `Tet` facade only.
- [ ] Web modules do not own policy, state machines, provider adapters, tools,
      store, approval gates, repair, or runtime supervision.
- [ ] Contract ties back to ADR-0001 through ADR-0005.
- [ ] Future BD-0009 removability and xref/facade-only gate are named.
- [ ] `tools/check_web_facade_contract.sh` passes without Phoenix installed.
