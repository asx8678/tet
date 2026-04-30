# Tet standalone umbrella boundary

This repository contains the minimal Elixir umbrella/release scaffold plus the
first standalone streaming chat path for `tet-db6.5` / `BD-0005`.

The implementation stays CLI-first and OTP-first. The CLI parses arguments and
renders streamed chunks; runtime owns session orchestration, provider selection,
stream fanout, and persistence; core owns pure contracts and event/message
shapes; the store app persists messages behind the `Tet.Store` behaviour. No
Phoenix, LiveView, Plug, Cowboy, or web adapter dependency is part of this
standalone path. Architectural lasagna remains illegal, thank goodness.

## Standalone closure

The `tet_standalone` release contains these conceptual applications:

| App | Boundary role | Current implementation scope |
|---|---|---|
| `tet_core` | Pure domain/contracts boundary | Metadata, `%Tet.Event{}`, `%Tet.Message{}`, `Tet.Provider` behaviour, and `Tet.Store` behaviour |
| `tet_store_sqlite` | Default standalone store adapter boundary | Dependency-free durable JSON Lines message store for this phase; true SQLite can replace the file format later behind the same behaviour |
| `tet_runtime` | OTP runtime and public `Tet.*` facade owner | Supervised runtime shell, Registry-backed event bus, `Tet.doctor/1`, `Tet.ask/2`, provider config, mock provider, and OpenAI-compatible streaming adapter |
| `tet_cli` | Thin terminal adapter | `tet ask`, `tet doctor`, and help output through the public facade |

The standalone release explicitly excludes:

- `tet_web_phoenix` or any `tet_web*` application;
- Phoenix and LiveView applications;
- Plug and Cowboy applications;
- common web adapter/server applications such as Bandit, Ranch, Thousand Island,
  and WebSock adapters.

No Phoenix/web dependency has been added to `mix.exs`, any child app, or
`mix.lock`.

## Runtime requirements

The project uses Erlang/OTP's built-in `:json` module for dependency-free JSON
encoding/decoding, so builds require Erlang/OTP 27 or newer. `mix.exs` pins this
with `erlang: ">= 27.0"`.

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

`tools/check_release_closure.sh` builds the release by default. Pass
`--no-build` only when you already built
`MIX_ENV=prod mix release tet_standalone --overwrite` and want to inspect the
existing artifact.

## `tet ask` streaming chat

After building the release, the overlayed convenience wrapper can run a one-shot
chat turn:

```bash
TET_PROVIDER=mock TET_STORE_PATH=/tmp/tet-smoke/messages.jsonl \
  _build/prod/rel/tet_standalone/bin/tet ask "hello standalone"
```

Expected mock output streams as assistant chunks and then the CLI writes a final
newline:

```text
mock: hello standalone
```

The release-native script also works:

```bash
_build/prod/rel/tet_standalone/bin/tet_standalone eval \
  'Tet.CLI.Release.main(["ask", "hello standalone"])'
```

The existing doctor command remains available:

```bash
_build/prod/rel/tet_standalone/bin/tet doctor
```

Expected doctor output includes:

```text
Tet standalone doctor: ok
profile: tet_standalone
applications: tet_core, tet_store_sqlite, tet_runtime, tet_cli
```

## Provider configuration

Provider selection is runtime configuration, not CLI business logic.

### Mock provider

The deterministic mock provider is the default configured provider and is used
by tests and local smoke checks:

```bash
TET_PROVIDER=mock tet ask "hello"
```

It streams three chunks for the default response:

1. `mock`
2. `: `
3. the user prompt

That makes streaming observable in tests without pretending a final string is a
stream. Sneaky fake-streams are how bugs get tenure.

### OpenAI-compatible provider

A minimal OpenAI-compatible adapter is available via Erlang `:httpc`. It posts
to `/chat/completions` with `stream: true` and consumes Server-Sent Event
`data:` chunks from the response.

Required environment variable:

- `TET_OPENAI_API_KEY` — API key used as `Authorization: Bearer ...`.

Optional environment variables:

- `TET_PROVIDER=openai_compatible` — selects the adapter. `openai` is accepted
  as a shorthand.
- `TET_OPENAI_BASE_URL` — base URL; defaults to `https://api.openai.com/v1`.
- `TET_OPENAI_MODEL` — model name; defaults to `gpt-4o-mini`.
- `TET_STORE_PATH` — message log path; defaults to `.tet/messages.jsonl`.

OpenAI-compatible streams are considered complete only after a `data: [DONE]`
SSE payload. Missing `[DONE]`, content after `[DONE]`, and non-empty trailing
SSE buffers are rejected as incomplete/malformed so partial assistant turns are
not persisted as successful responses.

Example:

```bash
TET_PROVIDER=openai_compatible \
TET_OPENAI_API_KEY="$OPENAI_API_KEY" \
TET_OPENAI_MODEL="gpt-4o-mini" \
TET_STORE_PATH="$PWD/.tet/messages.jsonl" \
  _build/prod/rel/tet_standalone/bin/tet ask "say hi in five words"
```

No secrets are stored in config files. Tests use the mock provider and a local
TCP fake OpenAI-compatible stream server; they do not call real provider APIs.

## Persistence

Successful `tet ask` turns persist both messages:

- user message;
- assistant message assembled from streamed assistant chunks.

Each persisted message contains at least:

- `id`;
- `session_id`;
- `role`;
- `content`;
- `timestamp`;
- `metadata`.

Current default path:

```text
.tet/messages.jsonl
```

The storage ADR reserves `.tet/tet.sqlite` as the eventual default database. For
this phase, adding and migrating a real SQLite dependency would be premature:
acceptance needs durable messages and a clean boundary, not a fake schema
ceremony. The `tet_store_sqlite` application therefore writes JSON Lines behind
`Tet.Store.save_message/2` and `Tet.Store.list_messages/2`; downstream storage
work can replace the internals with SQLite while keeping runtime and CLI callers
unchanged.

## Architecture notes preserved

The scaffold and chat path follow the accepted ADR rules:

- CLI is the default product boundary.
- `Tet.*` facade lives in `tet_runtime`, not `tet_core`.
- `tet_core` stays pure and does not supervise processes or depend on adapters.
- Runtime uses OTP primitives and a runtime-owned event bus, not Phoenix PubSub.
- Runtime owns session orchestration, provider selection, streaming, and store
  dispatch.
- Store access is behind the core `Tet.Store` behaviour.
- Provider adapters implement the core `Tet.Provider` behaviour and live in the
  runtime boundary.
- CLI calls the public `Tet` facade and does not call runtime/store/provider
  internals.
- Phoenix remains optional/removable and absent from standalone closure.

## What this issue deliberately does not do

- No broad provider framework or model registry.
- No tool calls, patch application, approval workflow, or verifier execution.
- No Ecto schemas, migrations, or true SQLite dependency yet.
- No Phoenix app, endpoint, router, LiveView, Plug, Cowboy, or web release.
