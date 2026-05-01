# 08 — Release Profiles, Testing, and Acceptance

## Release A — `tet_standalone`

Includes:

```text
tet_core
tet_runtime
tet_cli
tet_store_sqlite
selected provider adapter
```

Excludes:

```text
phoenix
phoenix_live_view
phoenix_pubsub
plug
cowboy
tet_web_phoenix
TetWeb.Endpoint
web assets
```

This is the default product.

## Release B — `tet_web`

Includes:

```text
tet_core
tet_runtime
tet_cli optional
tet_store_sqlite or tet_store_postgres
tet_web_phoenix
phoenix
phoenix_live_view
```

This is the optional browser UI or hosted/team deployment.

## Release C — `tet_runtime_only`

Includes:

```text
tet_core
tet_runtime
selected store adapter
```

Excludes CLI and Phoenix. Use for embedding or future adapters.

## Testing layers

### 1. Core unit tests

- command validation;
- event serialization;
- policy reason atoms;
- mode policy matrix;
- approval state transitions;
- patch validation model;
- redaction;
- provider/tool/store behaviour contracts.

### 2. Storage contract tests

Run the same contract suite against:

- `Tet.Store.Memory`;
- `Tet.Store.SQLite`;
- optional `Tet.Store.Postgres`.

Check workspace/session/message/tool_run/approval/artifact/event operations and transaction behavior.

### 3. Runtime integration tests

- application starts without Phoenix;
- session supervisors start/stop workers;
- event bus publishes ordered events;
- provider errors become events;
- tools obey policy and timeouts;
- patch proposals create artifacts and approvals;
- verifier captures output and exit status.

### 4. CLI tests

- argv parsing;
- command behavior;
- exit codes;
- rendering of events/diffs/approvals;
- no endpoint starts;
- first milestone script.

### 5. Boundary guards

- dependency closure;
- xref;
- source grep;
- runtime smoke;
- release closure;
- facade-only UI guard;
- Phoenix removability test.

### 6. Optional Phoenix tests

- LiveViews mount and call `Tet.*`;
- LiveViews subscribe via `Tet.subscribe/1`;
- approve/reject buttons call facade;
- no business logic in LiveViews;
- endpoint starts only in web release.

## Acceptance criteria

The redesign succeeds only if all are true:

1. `mix release tet_standalone` produces a CLI-capable release.
2. The standalone release closure contains zero Phoenix/Plug/Cowboy/LiveView libs.
3. `Tet.Application` starts without `TetWeb.Endpoint`.
4. CLI can initialize, trust, create sessions, chat, explore, propose patches, approve/reject patches, apply approved patches, run verification, and show status.
5. No module in `tet_core`, `tet_runtime`, or `tet_cli` references Phoenix, Plug, LiveView, `TetWeb`, `TetWeb.Endpoint`, or `Phoenix.PubSub`.
6. No UI module reaches past the `Tet` facade.
7. Storage adapters pass the same contract tests.
8. Policy-blocked tool attempts are persisted.
9. Patch application without approved approval row is impossible.
10. Removing `tet_web_phoenix` does not break the standalone compile/test/release path.
