# Tet standalone umbrella boundary

This repository now contains the minimal Elixir umbrella/release scaffold for `tet-db6.4` / `BD-0004`.

The scaffold is intentionally boring. It reserves the CLI-first application boundary and proves a standalone release can be built without dragging in Phoenix, LiveView, Plug, Cowboy, or a web adapter. It does **not** implement provider chat, patching, approvals, verification execution, schemas, migrations, or Phoenix. Future tickets get to do that work without turning the first boundary commit into architectural lasagna.

## Standalone closure

The `tet_standalone` release contains only these conceptual applications:

| App | Boundary role | Current implementation scope |
|---|---|---|
| `tet_core` | Pure domain/contracts boundary | Minimal metadata, `%Tet.Event{}`, and `Tet.Store` behaviour |
| `tet_store_sqlite` | Default standalone store adapter boundary | Dependency-free placeholder for `.tet/tet.sqlite`; schemas/migrations come later |
| `tet_runtime` | OTP runtime and public `Tet.*` facade owner | Supervised runtime shell, Registry-backed event bus placeholder, `Tet.doctor/1`, boundary guard helpers |
| `tet_cli` | Thin terminal adapter | `tet doctor` and help output through the public facade |

The standalone release explicitly excludes:

- `tet_web_phoenix` or any `tet_web*` application;
- Phoenix and LiveView applications;
- Plug and Cowboy applications;
- common web adapter/server applications such as Bandit, Ranch, Thousand Island, and WebSock adapters.

No Phoenix/web dependency has been added to `mix.exs`, any child app, or `mix.lock`.

## Build and check

From the repository root:

```bash
mix format --check-formatted
mix test
MIX_ENV=prod mix release tet_standalone --overwrite
tools/check_release_closure.sh --no-build
```

Or run the full standalone boundary alias:

```bash
mix standalone.check
```

`tools/check_release_closure.sh` builds the release by default. Pass `--no-build` only when you already built `MIX_ENV=prod mix release tet_standalone --overwrite` and want to inspect the existing artifact.

## Running the placeholder CLI

After building the release, the overlayed convenience wrapper can run the current doctor command:

```bash
_build/prod/rel/tet_standalone/bin/tet doctor
```

The release-native script also works:

```bash
_build/prod/rel/tet_standalone/bin/tet_standalone eval "Tet.CLI.Release.main([\"doctor\"])"
```

Expected output includes:

```text
Tet standalone doctor: ok
profile: tet_standalone
applications: tet_core, tet_store_sqlite, tet_runtime, tet_cli
```

## What this issue deliberately does not do

- No provider adapter implementation.
- No streaming chat path.
- No database dependency, migrations, or schemas.
- No Phoenix app, endpoint, router, LiveView, Plug, Cowboy, or web release.
- No patch application, approval workflow, or verifier execution.

Those are downstream phase-1 and later tasks. This issue only makes the umbrella/release seam real and testable.

## Architecture notes preserved

The scaffold follows the already-merged ADR rules:

- CLI is the default product boundary.
- `Tet.*` facade lives in `tet_runtime`, not `tet_core`.
- `tet_core` stays pure and does not supervise processes or depend on adapters.
- Runtime uses OTP primitives and a runtime-owned event bus placeholder, not Phoenix PubSub.
- Store access is behind a core `Tet.Store` behaviour.
- CLI calls the public `Tet` facade and does not call runtime/store internals.
- Phoenix remains optional/removable and absent from standalone closure.
