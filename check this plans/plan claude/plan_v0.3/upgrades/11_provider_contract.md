# 11 — Provider Contract

The original plan spent five lines on the provider abstraction. This doc
is the contract.

> **v0.3 changelog:** stream-stall retry floor raised from 0s to 250ms
> (instant retry on stall amplifies overload). Tool-call normalization
> sketched as an actual bidirectional map for the two shipped adapters
> rather than asserted to "just work." `models.dev` integration moved
> from default-on to opt-in; bundled JSON is the v1 default. Round-robin
> moved to `extensions/` (v1.x).

## Goals

- One Elixir behaviour for every provider (Anthropic, OpenAI, OpenAI-
  compatible endpoints — local llama.cpp/vLLM/Ollama or third-party
  Cerebras/Groq/Mistral/Together/DeepInfra/xAI).
- Streaming as a normalized event sequence.
- Tool calls normalized to one shape regardless of provider wire format.
- Built-in retry, timeout, and stream-stall handling.
- A model registry driven by a JSON file the user can edit.
- Provider failures become events, never crashes.

## Behaviour

Lives in `tet_core` (pure, no IO):

```elixir
defmodule Tet.LLM.Provider do
  @type message :: %{
    role: :system | :user | :assistant | :tool,
    content: String.t() | [content_part()],
    tool_calls: [tool_call()] | nil,
    tool_call_id: String.t() | nil
  }

  @type content_part :: %{type: :text, text: String.t()}

  @type tool_call :: %{
    id: String.t(),
    name: String.t(),
    arguments: map()
  }

  @type tool_decl :: %{
    name: String.t(),
    description: String.t(),
    parameters_json_schema: map()
  }

  @type request :: %{
    messages: [message()],
    tools: [tool_decl()],
    model: String.t(),
    temperature: float() | nil,
    max_tokens: pos_integer() | nil,
    stop: [String.t()] | nil,
    request_id: String.t()        # idempotency key, see doc 12
  }

  @type stream_event ::
    {:started, %{request_id: String.t()}}
    | {:text_delta, %{text: String.t()}}
    | {:tool_call_delta, %{index: non_neg_integer(), id: String.t() | nil,
                            name: String.t() | nil, arguments_delta: String.t()}}
    | {:tool_call_done, %{index: non_neg_integer(), id: String.t(),
                           name: String.t(), arguments: map()}}
    | {:usage, %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()}}
    | {:done, %{stop_reason: :stop | :length | :tool_use | :error}}
    | {:error, %{kind: atom(), retryable?: boolean(), detail: term()}}

  @callback stream(request(), config :: map()) ::
    {:ok, Enumerable.t()} | {:error, term()}
end
```

`request_id` is mandatory and is the idempotency key. See doc 12
§"Idempotency input scope" for how it's derived.

## Provider implementations

Implementations live in `tet_runtime` for v1
(`apps/tet_runtime/lib/tet/llm/providers/`) and may move to dedicated
`tet_provider_*` apps later. v1 ships two adapters:

```text
Tet.LLM.Providers.Anthropic         direct, native message format
Tet.LLM.Providers.OpenAICompatible  /v1/chat/completions; covers OpenAI,
                                    Cerebras, Groq, Mistral, Together,
                                    DeepInfra, xAI, local llama.cpp/vLLM
```

Other adapters (Gemini, Bedrock, etc.) live behind the same behaviour
but are out of v1 scope.

## Tool-call normalization — the bidirectional map

Both adapters convert between provider-native shapes and the in-process
form. This was hand-waved in v0.2; here is the actual mapping.

### In-process shape (single source of truth)

```elixir
%Tet.LLM.ToolCall{
  id: "call_8f3a21",      # provider-assigned or generated
  name: "read_file",
  arguments: %{"path" => "lib/foo.ex"}
}
```

### Anthropic Messages API

**Outbound (Tet → Anthropic).** Tools become a top-level `tools` array
on the request body:

```json
"tools": [{
  "name": "read_file",
  "description": "...",
  "input_schema": {...}
}]
```

Tet's previous `tool_call` becomes an assistant message with a
`tool_use` content block:

```json
{"role": "assistant", "content": [
  {"type": "tool_use", "id": "toolu_...", "name": "read_file",
   "input": {"path": "lib/foo.ex"}}
]}
```

The previous tool result becomes a user message with a `tool_result`
content block:

```json
{"role": "user", "content": [
  {"type": "tool_result", "tool_use_id": "toolu_...", "content": "..."}
]}
```

**Inbound (Anthropic stream → Tet).** Anthropic uses
`message_start`, `content_block_start`, `content_block_delta`,
`content_block_stop`, `message_delta`, `message_stop` events.

| Anthropic event                                            | Tet emit                            |
| ---------------------------------------------------------- | ----------------------------------- |
| `message_start`                                            | `:started`                          |
| `content_block_start { type: "text" }`                     | (track index; emit nothing)         |
| `content_block_delta { type: "text_delta" }`               | `:text_delta`                       |
| `content_block_start { type: "tool_use", id, name }`       | (track index; buffer name+id)       |
| `content_block_delta { type: "input_json_delta" }`         | `:tool_call_delta`                  |
| `content_block_stop` for a tool_use block                  | `:tool_call_done` (parsed JSON)     |
| `message_delta { usage }`                                  | `:usage`                            |
| `message_stop`                                             | `:done` with mapped `stop_reason`   |

`stop_reason` maps: `"end_turn"` → `:stop`, `"max_tokens"` → `:length`,
`"tool_use"` → `:tool_use`, anything else → `:error`.

### OpenAI Chat Completions

**Outbound (Tet → OpenAI-compatible).** Tools become a top-level
`tools` array:

```json
"tools": [{
  "type": "function",
  "function": {"name": "read_file", "description": "...", "parameters": {...}}
}]
```

A previous tool call becomes an assistant message with `tool_calls`:

```json
{"role": "assistant", "content": null, "tool_calls": [
  {"id": "call_...", "type": "function",
   "function": {"name": "read_file", "arguments": "{\"path\":\"lib/foo.ex\"}"}}
]}
```

Note the arguments are a JSON-encoded *string* in OpenAI's wire format,
not an object. The adapter encodes/decodes.

The previous tool result is a `role: "tool"` message:

```json
{"role": "tool", "tool_call_id": "call_...", "content": "..."}
```

**Inbound (OpenAI stream → Tet).** OpenAI streams SSE chunks with
`choices[0].delta.{content, tool_calls}`.

| OpenAI delta                                              | Tet emit                            |
| --------------------------------------------------------- | ----------------------------------- |
| First chunk                                               | `:started`                          |
| `delta.content` non-empty                                 | `:text_delta`                       |
| `delta.tool_calls[i].id` first appearance                 | (track id at index i)               |
| `delta.tool_calls[i].function.name` first appearance      | (track name at index i)             |
| `delta.tool_calls[i].function.arguments` (string fragment)| `:tool_call_delta`                  |
| `finish_reason: "tool_calls"`                             | `:tool_call_done` for each i, then `:done` with `:tool_use` |
| `finish_reason: "stop"`                                   | `:done` with `:stop`                |
| `finish_reason: "length"`                                 | `:done` with `:length`              |
| Final chunk's `usage` (when provider sends it)            | `:usage`                            |

OpenAI usage is sent only when `stream_options: {include_usage: true}`
is requested; the adapter sets this. Providers that don't honor it
emit no `:usage` event, which is allowed.

### Round-trip property test

For each adapter, a property test:

1. Generate random `Tet.LLM.ToolCall` lists.
2. Serialize to provider-native shape.
3. Replay through the inbound parser as a single non-streamed
   response.
4. Assert the output equals the input.

This is the conformance test for "the bidirectional map is correct."

## Streaming

The runtime consumes the provider stream lazily via a `Stream`
returned from `stream/2`. Every event is recorded into the workflow
journal (doc 12) before being acted on. Text deltas accumulate into
the final assistant message; tool-call deltas accumulate into a
complete tool call; `:done` triggers tool dispatch or final-message
persistence.

Provider streams are wrapped in a `Task` supervised by
`Tet.LLM.TaskSupervisor`. Cancellation kills the task and emits
`provider.error` with `kind: :cancelled` if mid-stream.

## Retries and timeouts

Each provider call has two timeouts:

- **Connect timeout** (5s default, per-provider configurable) — fails
  fast on dead endpoints.
- **Stream-stall timeout** (30s default) — if no event arrives for
  this long, the call is retried.

Retries are owned by the runtime, not the provider:

| Failure                          | Retryable | Default backoff                  |
| -------------------------------- | --------- | -------------------------------- |
| Connect timeout                  | yes       | 1s, 2s, 4s; give up after 3      |
| HTTP 5xx                         | yes       | 1s, 2s, 4s; give up after 3      |
| HTTP 429                         | yes       | honor `Retry-After`; cap at 60s  |
| Stream stall                     | yes       | **250ms floor**, then 1s, 2s     |
| HTTP 4xx (auth/validation)       | no        | fail immediately                 |
| Tool-args JSON invalid           | no        | fail immediately                 |
| Cancelled by user                | no        | fail immediately                 |

A 0s stall retry amplifies overload (the cause of the stall is often
upstream load); the 250ms floor lets in-flight congestion clear.

Retry attempts each commit a separate `provider_call:attempt:N` step.
The journal sees each HTTP request explicitly; a recovery operator
can audit attempts independently.

## Model registry

Two layers, opt-in escalation:

### Bundled (default in v1)

A static `priv/models.json` ships with the `tet_runtime` app. Sample:

```json
{
  "anthropic-claude-sonnet": {
    "provider": "anthropic",
    "model": "claude-sonnet-4-20250514",
    "context_window": 200000,
    "supports_tool_calls": true,
    "input_token_price_per_million": 3.0,
    "output_token_price_per_million": 15.0
  },
  "openai-gpt4o": {
    "provider": "openai_compatible",
    "base_url": "https://api.openai.com/v1",
    "model": "gpt-4o",
    "context_window": 128000,
    "supports_tool_calls": true
  }
}
```

`tet model list` and `tet model show <id>` read from the bundled
registry plus user overrides at `~/.config/tet/models.json` (workspace
overrides at `<workspace>/.tet/models.json` win).

### Live `models.dev` (opt-in, post-v1)

`tet model refresh` (when added) fetches from `https://models.dev`,
caches under `~/.cache/tet/models.dev.json` with a 24h TTL, and merges
into the registry. **This is not a runtime dependency** — Tet works
fully offline against the bundled file. Adopting `models.dev`
introduces a third-party API surface; keeping it opt-in lets users
audit the data flow.

Models without `supports_tool_calls: true` refuse to bind to
`:explore` or `:execute` sessions and produce
`:provider_lacks_tool_calls` at session creation. Pure-chat sessions
(`:chat` mode) can still use them.

## Error taxonomy

```text
:auth_failed             :rate_limited       :context_length_exceeded
:model_not_found         :tool_args_invalid  :provider_unavailable
:network_error           :timeout            :cancelled
:invalid_response        :content_filtered   :unknown
:provider_uncommitted_attempt    # used by recovery; see doc 12
```

Every `provider.error` event carries one of these atoms in
`payload.kind` and the original provider response in `payload.detail`
(redacted per doc 14).

## Acceptance

- [ ] `Tet.LLM.Provider` behaviour defined in `tet_core` with the
      shapes above.
- [ ] Two adapters ship in v1 (`Anthropic`, `OpenAICompatible`).
- [ ] Tool calls round-trip through both adapters via property tests
      against the bidirectional maps documented above.
- [ ] Retry/timeout/stream-stall behavior covered by tests using a
      fault-injecting fake provider; stream-stall retry honors the
      250ms floor.
- [ ] Bundled model registry loads on first call; user overrides at
      `~/.config/tet/models.json` win over bundled.
- [ ] `tet model list` and `tet model show` work without network
      access.
- [ ] Models without tool-call support are rejected from explore /
      execute sessions with `:provider_lacks_tool_calls`.
- [ ] No provider-specific types leak past `Tet.LLM.Providers.*`.
