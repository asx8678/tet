# 02 — Dependency Rules and Guards

## Dependency direction

```text
tet_cli           ─┐
tet_web_phoenix   ├──► tet_runtime ───► tet_core
tet_provider_*    ┘          │
                             │ behaviour calls / configured module
                             ▼
tet_store_memory/sqlite/postgres ───► tet_core
```

The direction is inward toward core contracts, with runtime as the side-effect ring.

## Allowed dependencies

```text
tet_core          -> Elixir/OTP stdlib, small serialization libs if needed
tet_runtime       -> tet_core, configured adapter modules, provider libs, tool libs
tet_cli           -> tet_runtime, tet_core, terminal/argv libraries
tet_store_memory  -> tet_core
tet_store_sqlite  -> tet_core, ecto_sql, sqlite adapter
tet_store_postgres-> tet_core, ecto_sql, postgrex
tet_web_phoenix   -> tet_runtime, tet_core, phoenix, phoenix_live_view, plug/cowboy
tet_provider_*    -> tet_core and provider-specific client deps
```

## Forbidden dependencies

| Forbidden in | Forbidden references | Reason |
|---|---|---|
| `tet_core/**` | `Tet.Runtime`, `TetWeb`, `Phoenix`, `Phoenix.LiveView`, `Phoenix.PubSub`, `Plug`, `Ecto`, `Tet.CLI`, `Tet.Store.SQLite` | Core must remain pure and adapter-free. |
| `tet_runtime/**` | `TetWeb`, `Phoenix`, `Phoenix.LiveView`, `Phoenix.PubSub`, `Plug`, `Tet.CLI` | Runtime is web/UI agnostic. |
| `tet_cli/**` | `TetWeb`, `Phoenix`, `Plug`, direct store internals, runtime internals except `Tet.*` | CLI is a thin driving adapter. |
| `tet_store_*/**` | `Tet.Runtime`, `Tet.CLI`, `TetWeb`, `Phoenix`, `Plug` | Storage adapters implement the core behaviour only. |
| anywhere outside web | `Phoenix.PubSub` for runtime/session events | Runtime events use `Tet.EventBus`. |

## The five gates

### Gate B1 — Mix dependency closure

Build/inspect the standalone dependency tree and fail if any web framework appears in the standalone closure.

### Gate B2 — `mix xref` source graph

Fail if core/runtime/CLI/stores contain compile-time edges to forbidden apps or modules.

### Gate B3 — source grep guard

Fail if source text includes forbidden module references. This catches obvious mistakes early and gives fast feedback.

### Gate B4 — runtime smoke test

Boot `Tet.Application` in test/prod-like config and assert:

- `Tet.doctor/1` works;
- no `TetWeb.Endpoint` process exists;
- `Application.spec(:phoenix, :vsn)` returns nil in standalone mode;
- no Phoenix/Plug/Cowboy applications are started.

### Gate B5 — release closure check

Build `tet_standalone` and inspect `_build/prod/rel/tet_standalone/lib`. The release fails if it contains `phoenix*`, `phoenix_live_view*`, `phoenix_pubsub*`, `plug*`, or `cowboy*`.

## Sixth practical guard — facade-only UI

CLI and Phoenix modules may call `Tet.*` and pattern-match on core structs/events. They may not call:

```text
Tet.Runtime.*
Tet.EventBus.*
Tet.Tool.*
Tet.Tools.*
Tet.Prompt.*
Tet.Store.*
Tet.Store.SQLite.*
Tet.Agent.Runtime.*
```

A grep/xref guard should fail any UI app that reaches past the facade.

## Removability test

A CI job temporarily removes or excludes `apps/tet_web_phoenix` and runs:

```bash
mix compile --warnings-as-errors
mix test
MIX_ENV=prod mix release tet_standalone --overwrite
tools/check_release_closure.sh
```

If removing Phoenix breaks the CLI/runtime, Phoenix was not optional.
