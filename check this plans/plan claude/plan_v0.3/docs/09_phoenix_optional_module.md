# 09 — Phoenix LiveView as an Optional Module

## Hard rule

```text
Phoenix renders Tet. Phoenix does not own Tet.
```

## Allowed dependency direction

```text
tet_web_phoenix -> tet_runtime -> tet_core
tet_web_phoenix -> phoenix/liveview/plug
```

Forbidden:

```text
tet_core    -> tet_web_phoenix | Phoenix | Plug | LiveView
tet_runtime -> tet_web_phoenix | Phoenix | Plug | LiveView
tet_cli     -> tet_web_phoenix | Phoenix | Plug | LiveView
```

## Phoenix may render

- dashboard;
- session timeline;
- transcript;
- tool activity;
- pending approval panel;
- diff preview;
- verification output;
- prompt debug drawer;
- health/status routes for the web release.

## Phoenix must not contain

- LLM provider calls;
- path/mode/trust/command policy;
- prompt composition;
- patch application;
- verifier execution;
- storage ownership;
- session runtime supervision;
- duplicated approval state machine;
- business rules copied from core/runtime.

## LiveView pattern

A valid LiveView is shallow:

```text
mount -> Tet.get_session/1 + Tet.list_events/2 + Tet.subscribe/1
handle_event("send_prompt") -> Tet.send_prompt/3
handle_event("approve") -> Tet.approve_patch/3
handle_event("reject") -> Tet.reject_patch/3
handle_info(%Tet.Event{}) -> update assigns/render
```

No LiveView calls `Tet.Runtime.*`, `Tet.Store.*`, `Tet.Tools.*`, or provider modules.

## Deployment modes after v1

### Mode A — local companion UI

User runs a web-capable release locally. Phoenix connects to the same local `.tet/tet.sqlite` and event bus.

### Mode B — hosted/team UI

A server release uses `tet_store_postgres`. The same `Tet` facade and event types apply. Postgres is selected by config/release, not by Phoenix ownership.

## Phoenix acceptance

The optional web module is accepted only when:

- standalone release still builds without it;
- LiveView can display a CLI-created session;
- LiveView can approve/reject through `Tet.*`;
- CLI and LiveView receive the same event sequence for the same session;
- no web module duplicates policy, patch, provider, prompt, verifier, or storage logic.
