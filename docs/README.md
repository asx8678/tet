# Tet standalone umbrella boundary

This repository contains the minimal Elixir umbrella/release scaffold plus the
standalone streaming chat, session resume, event timeline shell,
autosave/restore checkpoints, Prompt Lab model/history storage, and doctor
diagnostics path through `tet-db6.6` / `BD-0006`. It includes the optional web
facade contract from `tet-db6.7` / `BD-0007`, the event timeline shell from
`tet-db6.8` / `BD-0008`, the web removability gate from `tet-db6.9` /
`BD-0009`, the prompt-layer contract from `tet-db6.10` / `BD-0010`,
autosave/restore checkpoints from `tet-db6.11` / `BD-0011`, and the Prompt Lab
preset/refiner model from `tet-db6.47` / `BD-0047`.

The implementation stays CLI-first and OTP-first. The CLI parses arguments and
renders streamed chunks; runtime owns session orchestration, provider selection,
stream fanout, and persistence; core owns pure contracts plus message, session,
autosave, and event shapes; the store app persists messages, autosave
checkpoints, and timeline events while deriving session summaries behind the
`Tet.Store` behaviour. No Phoenix, LiveView, Plug, Cowboy, or web adapter
dependency is part of this standalone path. Architectural lasagna remains
illegal, thank goodness.

## Standalone closure

The `tet_standalone` release contains these conceptual applications:

| App | Boundary role | Current implementation scope |
|---|---|---|
| `tet_core` | Pure domain/contracts boundary | Metadata, `%Tet.Event{}`, `%Tet.Message{}`, `%Tet.Session{}`, `%Tet.Autosave{}`, `Tet.Prompt`, `Tet.PromptLab`, `Tet.Provider` behaviour, and `Tet.Store` behaviour |
| `tet_store_sqlite` | Default standalone store adapter boundary | Dependency-free durable JSON Lines message, derived-session, autosave checkpoint, event timeline, and Prompt Lab history store for this phase; true SQLite can replace the file format later behind the same behaviour |
| `tet_runtime` | OTP runtime and public `Tet.*` facade owner | Supervised runtime shell, Registry-backed event bus, `Tet.doctor/1`, `Tet.ask/2`, session query/resume/autosave orchestration, Prompt Lab facade/history orchestration, `Tet.list_events/1/2`, `Tet.subscribe_events/0/1`, provider config, mock provider, and OpenAI-compatible streaming adapter |
| `tet_cli` | Thin terminal adapter | `tet ask`, `tet events`, `tet timeline`, `tet sessions`, `tet session show`, `tet doctor`, and help output through the public facade |

The standalone release explicitly excludes:

- `tet_web_phoenix` or any `tet_web*` application;
- Phoenix and LiveView applications;
- Plug and Cowboy applications;
- common web adapter/server applications such as Bandit, Ranch, Thousand Island,
  and WebSock adapters.

No Phoenix/web dependency has been added to `mix.exs`, any child app, or
`mix.lock`.

## Optional web adapter facade contract

BD-0007 defines the future optional `tet_web_phoenix` adapter as a facade-only
caller of public `Tet.*` runtime APIs. The contract is documented in
[BD-0007 — Optional `tet_web_phoenix` adapter facade contract](BD-0007_OPTIONAL_WEB_ADAPTER_FACADE_CONTRACT.md).

Short version: Phoenix may own browser/HTTP/LiveView presentation concerns, but
it must not own Tet policy, state machines, providers, tools, storage, approval
gates, repair, verifier execution, or runtime supervision. Future web actions
must call the same public facade used by `tet_cli`.

A standalone-safe source guard is available:

```bash
tools/check_web_facade_contract.sh
# or
mix web.facade_contract
```

The guard succeeds when `apps/tet_web_phoenix` is absent and checks obvious
facade-contract violations if that optional app is introduced later.

## Web removability gate

BD-0009 adds a local CI-like removability gate documented in
[BD-0009 — Web removability acceptance gate](BD-0009_WEB_REMOVABILITY_GATE.md).
It proves the standalone path compiles, tests, and assembles its release after
optional `apps/tet_web*` directories are deleted from a sandbox copy.

Run it directly:

```bash
tools/check_web_removability.sh
```

or through Mix:

```bash
mix web.removability
```

The gate builds on `tools/check_web_facade_contract.sh`,
`tools/check_release_closure.sh`, and `mix standalone.check`. It also runs a
negative smoke that injects a temporary non-web Phoenix dependency and verifies
the source/dependency guard rejects it. No Phoenix dependency is installed or
required for the standalone proof.

## Runtime requirements

The project uses Erlang/OTP's built-in `:json` module for dependency-free JSON
encoding/decoding, so builds require Erlang/OTP 27 or newer. `mix.exs` pins this
with `erlang: ">= 27.0"`.

## Build and check

From the repository root:

```bash
mix format --check-formatted
mix web.facade_contract
mix test
tools/check_web_removability.sh
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

A quick release smoke for session resume uses the mock provider and a disposable
store:

```bash
STORE=$(mktemp /tmp/tet-session-smoke.XXXXXX)
TET_PROVIDER=mock TET_STORE_PATH="$STORE" \
  _build/prod/rel/tet_standalone/bin/tet ask --session smoke-session "first"
TET_PROVIDER=mock TET_STORE_PATH="$STORE" \
  _build/prod/rel/tet_standalone/bin/tet ask --session smoke-session "second"
TET_STORE_PATH="$STORE" _build/prod/rel/tet_standalone/bin/tet session show smoke-session
TET_STORE_PATH="$STORE" _build/prod/rel/tet_standalone/bin/tet events --session smoke-session
```

The session command should show four messages under `smoke-session`; the events
command should show the read-only runtime timeline for the same session.

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

## Session list/show/resume

Every successful `tet ask` turn has a `session_id`. A new id is generated when
no id is supplied and can be discovered with `tet sessions`; pass
`--session SESSION_ID` to append a new turn to an existing session and send the
resumed message history to the provider:

```bash
STORE=/tmp/tet-smoke/messages.jsonl

TET_PROVIDER=mock TET_STORE_PATH="$STORE" \
  _build/prod/rel/tet_standalone/bin/tet ask --session demo-session "first turn"

TET_PROVIDER=mock TET_STORE_PATH="$STORE" \
  _build/prod/rel/tet_standalone/bin/tet ask --session demo-session "second turn"
```

List persisted sessions:

```bash
TET_STORE_PATH="$STORE" _build/prod/rel/tet_standalone/bin/tet sessions
```

Example output:

```text
Sessions:
  demo-session  messages=4 updated=2025-... last=assistant: mock: second turn
```

Show one session and its messages:

```bash
TET_STORE_PATH="$STORE" \
  _build/prod/rel/tet_standalone/bin/tet session show demo-session
```

Example output:

```text
Session demo-session
messages: 4
started_at: 2025-...
updated_at: 2025-...
Messages:
  [user] first turn
  [assistant] mock: first turn
  [user] second turn
  [assistant] mock: second turn
```

CLI stays intentionally boring here: it parses `--session`, lists summaries, and
renders messages. Runtime owns resume orchestration, and the store owns durable
session/message queries behind `Tet.Store`. Boring boundaries are good. Spicy
boundaries are how apps become haunted.

## Runtime event timeline

Runtime emits `%Tet.Event{}` terms for core chat activity and owns live fanout via
`Tet.EventBus`. The public facade exposes two read-only timeline paths:

- `Tet.list_events/1` / `Tet.list_events/2` lists persisted runtime events,
  optionally filtered by session id.
- `Tet.subscribe_events/0` subscribes the caller to future runtime events on the
  all-events topic.
- `Tet.subscribe_events(session_id)` subscribes the caller to future events for
  one session and receives messages shaped as
  `{:tet_event, {:session, session_id}, %Tet.Event{}}`.

The CLI equivalent renders the same facade data without owning event state:

```bash
TET_PROVIDER=mock TET_STORE_PATH="$STORE" \
  _build/prod/rel/tet_standalone/bin/tet ask --session demo-session "timeline me"

TET_STORE_PATH="$STORE" \
  _build/prod/rel/tet_standalone/bin/tet events --session demo-session
```

`tet timeline` is an alias for `tet events`:

```bash
TET_STORE_PATH="$STORE" \
  _build/prod/rel/tet_standalone/bin/tet timeline --session demo-session
```

Example output:

```text
Events:
  #1 2025-... session=demo-session message_persisted role=user message_id=msg_...
  #2 2025-... session=demo-session assistant_chunk content="mock" provider=mock
  #3 2025-... session=demo-session assistant_chunk content=": " provider=mock
  #4 2025-... session=demo-session assistant_chunk content="timeline me" provider=mock
  #5 2025-... session=demo-session message_persisted role=assistant message_id=msg_...
```

The default store persists events to a sibling JSON Lines file derived from
`TET_STORE_PATH` (for example `/tmp/messages.events.jsonl`). Set
`TET_EVENTS_PATH` only when a separate event-log path is needed. This is still a
minimal timeline shell, not a broad event-store architecture wearing a fake
mustache.

Future optional LiveView parity should render the same `Tet.list_events/*` data
and subscribe through the same `Tet.subscribe_events/*` facade. Phoenix remains
optional/removable: no LiveView, Phoenix, Plug, Cowboy, or web dependency is part
of this standalone timeline path.

## Doctor diagnostics

The doctor command checks runtime config, store path read/write health, provider
configuration, and the standalone release boundary:

```bash
_build/prod/rel/tet_standalone/bin/tet doctor
```

Expected healthy output includes:

```text
Tet standalone doctor: ok
profile: tet_standalone
applications: tet_core, tet_store_sqlite, tet_runtime, tet_cli
store: Tet.Store.SQLite (ok)
provider: :mock (ok)
release_boundary: ok
checks:
  [ok] config - runtime config loaded
  [ok] store - store path is readable and writable
  [ok] provider - mock provider selected
  [ok] release_boundary - standalone closure excludes web applications
```

Selecting the OpenAI-compatible provider without an API key is diagnosable and
returns a non-zero doctor status without breaking the default mock provider path:

```bash
TET_PROVIDER=openai_compatible TET_OPENAI_API_KEY= tet doctor
```

Expected failing output includes:

```text
Tet standalone doctor: error
  [error] provider - OpenAI-compatible provider is missing required environment variable TET_OPENAI_API_KEY
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
- `TET_AUTOSAVE_PATH` — optional autosave checkpoint log path override; by
  default it is derived from `TET_STORE_PATH`.
- `TET_EVENTS_PATH` — optional event timeline log path override; by default it
  is derived from `TET_STORE_PATH`.
- `TET_PROMPT_HISTORY_PATH` — optional Prompt Lab history log path override; by
  default it is derived from `TET_STORE_PATH`.

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

## Prompt Lab

`Tet.PromptLab` defines Prompt Lab presets, quality dimensions, request/result
validation, redacted debug output, and prompt history storage for BD-0047. It is
advisory and non-executing: it improves prompt text without calling providers,
running tools, appending chat messages, writing autosaves, or emitting runtime
events.

Public facade calls:

```elixir
Tet.prompt_lab_presets()
Tet.get_prompt_lab_preset("coding")
Tet.refine_prompt("Implement the CLI command", preset: "coding")
Tet.refine_prompt("Preview only", persist?: false)
Tet.list_prompt_history()
Tet.fetch_prompt_history("prompt-history-...")
```

When persistence is enabled, runtime writes only the dedicated Prompt Lab history
store (`.tet/prompt_history.jsonl` by default). `persist?: false` returns a pure
preview with `history: nil`. Future dashboards must use the public `Tet.*`
facade to list presets/history and must not read store files or execute refined
prompts directly. See [`prompt_lab.md`](prompt_lab.md) for the model contract,
output shape, safety boundary, and dashboard guidance.

## Prompt layer contract

`Tet.Prompt` defines the pure, deterministic prompt build contract for system
prompts, project rules, profile/persona layers, compaction metadata, attachment
metadata, and session messages. It returns provider-neutral messages plus
redacted debug output with ordered layer ids, hashes, byte counts, and metadata
without dumping raw prompt content.

See [`prompt_contract.md`](prompt_contract.md) for the schema, fixed layer
order, debug output format, and the autosave/attachments handoff.

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

Current default message path:

```text
.tet/messages.jsonl
```

Sessions are derived from persisted messages and exposed as `%Tet.Session{}`
summaries with:

- `id`;
- `message_count`;
- `started_at`;
- `updated_at`;
- `last_role`;
- `last_content`.

The storage ADR reserves `.tet/tet.sqlite` as the eventual default database. For
this phase, adding and migrating a real SQLite dependency would be premature:
acceptance needs durable messages/sessions and a clean boundary, not a fake
schema ceremony. The `tet_store_sqlite` application therefore writes JSON Lines
behind the `Tet.Store` message/session callbacks here, plus the autosave and
timeline callbacks documented below; downstream storage work can replace the
internals with SQLite while keeping runtime and CLI callers unchanged.

## Autosave / restore checkpoints

Autosave checkpoints are explicit runtime snapshots. Callers build normal prompt
metadata through `Tet.Prompt`, then ask the runtime to autosave the already
persisted session:

```elixir
{:ok, checkpoint} =
  Tet.autosave_session("demo-session",
    [
      system: "You are Tet.",
      metadata: %{request_id: "req-123"},
      attachments: [
        %{
          id: "artifact-1",
          name: "notes.md",
          media_type: "text/markdown",
          byte_size: 512,
          sha256: "...",
          source: "fixture"
        }
      ]
    ],
    store_path: ".tet/messages.jsonl"
  )
```

`Tet.autosave_session/3` fetches messages from the configured store, injects
those messages into the prompt build, stores the latest prompt metadata/debug
artifacts, and appends a checkpoint record. It does **not** trust caller-supplied
`messages` fields in the prompt attrs; the message log remains the source of
truth. Fixture callers may pass deterministic `:checkpoint_id` and `:saved_at`
options, but normal runtime callers can omit them.

Autosaves are stored as JSON Lines at:

```text
.tet/autosaves.jsonl
```

The path is derived from the message log directory, so
`TET_STORE_PATH=/tmp/tet/messages.jsonl` uses `/tmp/tet/autosaves.jsonl`.
Override it with either the runtime option `:autosave_path`, the
`TET_AUTOSAVE_PATH` environment variable, or `:tet_runtime, :autosave_path`
application config.

A checkpoint persists:

- copied `%Tet.Message{}` records for the restored session;
- normalized attachment metadata from `Tet.Prompt.attachment_metadata/1`;
- normalized prompt metadata (`prompt.metadata`);
- redacted structured prompt debug output from `Tet.Prompt.debug/1`;
- redacted line-oriented prompt debug text from `Tet.Prompt.debug_text/1`;
- checkpoint metadata supplied via `:autosave_metadata`.

Restore is intentionally side-effect-free:

```elixir
{:ok, restored} = Tet.restore_autosave("demo-session")
```

`Tet.restore_autosave/2` returns the newest `%Tet.Autosave{}` checkpoint for the
session. It does not append messages back into `.tet/messages.jsonl`; replaying a
snapshot into the primary message log would create duplicate turns and make
resumes spicy in the bad way. Use `Tet.list_autosaves/1` to inspect checkpoints
newest-first.

Attachment rules match the prompt contract exactly: autosave stores metadata
only. Top-level attachment payload keys `content`, `data`, `bytes`, and `body`
are rejected. Attachment paths or storage references, if present in metadata,
are treated as labels/references only; autosave does not read files and never
embeds raw attachment contents.

Prompt debug artifacts are stored as redacted debug data. Raw prompt content is
not included in debug output, while normal session messages are still persisted
as messages because they are the chat history being restored. If prompt metadata
contains sensitive operational values, keep them out of caller metadata or rely
on the redacted debug artifact for inspection.

## Architecture notes preserved

The scaffold and chat path follow the accepted ADR rules:

- CLI is the default product boundary.
- `Tet.*` facade lives in `tet_runtime`, not `tet_core`.
- `tet_core` stays pure and does not supervise processes or depend on adapters.
- Runtime uses OTP primitives and a runtime-owned event bus, not Phoenix PubSub.
- Runtime owns session orchestration, provider selection, streaming, and store
  dispatch.
- Prompt construction is a pure `tet_core` contract; provider adapters can
  consume its provider-neutral role/content messages.
- Prompt Lab is advisory/read-only except for its own prompt-history store.
- Store access is behind the core `Tet.Store` behaviour.
- Provider adapters implement the core `Tet.Provider` behaviour and live in the
  runtime boundary.
- CLI calls the public `Tet` facade and does not call runtime/store/provider
  internals.
- Phoenix remains optional/removable and absent from standalone closure.
- Any future `tet_web_phoenix` app is a facade-only web adapter; it may render
  runtime/core data and call public `Tet.*`, but it must not own Tet policy,
  state, providers, tools, storage, approvals, repair, or supervision.

## What this issue deliberately does not do

- No broad provider framework or model registry.
- No Prompt Lab tool execution, provider-backed refinement, or automatic prompt dispatch.
- No tool calls, patch application, approval workflow, or verifier execution.
- No Ecto schemas, migrations, or true SQLite dependency yet.
- No Phoenix app, endpoint, router, LiveView, Plug, Cowboy, or web release.
