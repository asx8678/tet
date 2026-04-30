# Tet prompt layer contract

`Tet.Prompt` is the pure core contract for building prompt inputs. It is
intentionally provider-neutral: no SDK request bodies, no HTTP details, no file
reads, and no persistence side effects. Runtime or future provider adapters can
call `Tet.Prompt.to_provider_messages/1` when they need simple role/content
chat input.

This contract was introduced for `tet-db6.10` / `BD-0010` so prompt builds are
deterministic and debuggable instead of being assembled from scattered runtime
string concatenation. Architectural spaghetti is delicious only when it is
actual spaghetti.

## Version

Current contract version:

```elixir
Tet.Prompt.version()
#=> "tet.prompt.v1"
```

The version is included in prompt hashes and debug output. A future schema break
should bump the version and add migration/snapshot coverage.

## Build input schema

`Tet.Prompt.build/1` accepts a map or keyword list with atom or string keys.
Unknown top-level keys are rejected.

| Key | Required? | Type | Notes |
|---|---:|---|---|
| `system` / `system_base` | yes | non-empty string | Base/system instructions. |
| `project_rules` | no | string, map, or list | Project/global rules. Map fields: `id`, `content`, `source`, `scope`, `label`, `name`, `path`, `persona`, `metadata`. |
| `profiles` / `profile_layers` / `personas` | no | string, map, or list | Profile/persona instructions. Same map fields as project rules. |
| `compaction` / `compactions` | no | map or list | Compacted conversation context. Fields below. |
| `attachments` | no | map or list | Attachment metadata only. Raw content is explicitly rejected. Fields below. |
| `messages` / `session_messages` | no | list of `%Tet.Message{}` or message maps | Existing session/user/assistant/tool messages. Uses the core `%Tet.Message{}` validation. |
| `metadata` / `prompt_metadata` | no | map | Prompt-level metadata. Included in hashes and redacted debug output. |

### Compaction fields

Compaction layers use system role and render a deterministic textual summary.
Accepted fields:

| Field | Type | Notes |
|---|---|---|
| `id` | string | Optional stable layer id. Generated when omitted. |
| `summary` | non-empty string | Required compaction summary shown to the model. |
| `source_message_ids` | list of non-empty strings | Optional source messages covered by the summary. |
| `strategy` | atom or string | Optional strategy name, normalized to string metadata. |
| `original_message_count` | non-negative integer | Optional source count. |
| `retained_message_count` | non-negative integer | Optional retained count. |
| `metadata` | map | Optional extra metadata. Sensitive keys are redacted in debug output. |

`Tet.Compaction.to_prompt_compactions/1` emits this shape for BD-0012 compacted
context. Its metadata includes the deterministic split contract used by runtime:
original count/range, retained count/ranges, compacted count/range, strategy,
sanitized options, tool-pair locations, protected tool-pair records, and orphaned
tool-call/result diagnostics. Prompt debug redacts metadata through the central
redactor and still does not print raw summary content.

### Attachment fields

Attachment layers use system role and render whitelisted metadata only. Accepted
fields:

| Field | Type | Notes |
|---|---|---|
| `id` | string | Optional stable attachment id. Generated from visible metadata when omitted. |
| `name` | string | Optional display name. |
| `media_type` | string | Optional MIME/media type. |
| `byte_size` / `size` | non-negative integer | Optional size in bytes. |
| `sha256` | string | Optional content digest supplied by the caller/storage layer. |
| `source` | string | Optional source label such as `upload` or `autosave`. |
| `metadata` | map | Optional control/debug metadata; not rendered into prompt content except through redacted debug output. |

Rejected attachment payload keys: `content`, `data`, `bytes`, and `body`. The
prompt layer carries metadata, not raw attachment bytes. Autosave checkpoints
reuse this same metadata-only rule: they may persist stable artifact ids, byte
sizes, digests, media types, source labels, and storage references, but they do
not make the prompt contract responsible for reading or embedding files.

## Layer order

Layer ordering is fixed by the contract:

1. `system_base`
2. `project_rules`
3. `profile`
4. `compaction_metadata`
5. `attachment_metadata`
6. `session_message`

Within a bucket, caller-provided list order is preserved. Generated layer ids
include the final layer index, kind, and content/metadata hash prefix, so the
same input produces the same ids and hashes. Explicit layer ids are validated
and duplicate final ids are rejected.

## Output shape

`Tet.Prompt.build/1` returns `{:ok, %Tet.Prompt{}}` or `{:error, reason}`.

The prompt struct contains:

| Field | Description |
|---|---|
| `id` | Stable `prompt-<hash-prefix>` id. |
| `version` | Contract version string. |
| `hash` | SHA-256 over version, ordered layer ids/hashes, and prompt metadata. |
| `metadata` | Normalized prompt metadata. |
| `layers` | Ordered `%Tet.Prompt.Layer{}` structs. |
| `messages` | Provider-neutral `%{role: atom, content: binary, metadata: map}` messages. |
| `debug` | Structured redacted debug map. |

Each `%Tet.Prompt.Layer{}` contains:

| Field | Description |
|---|---|
| `id` | Stable supplied/generated layer id. |
| `index` | Zero-based final order index. |
| `kind` | One of the layer kinds listed above. |
| `role` | Core chat role (`:system`, `:user`, `:assistant`, or `:tool`). |
| `content` | Raw prompt content for actual provider input. Not emitted by debug output. |
| `metadata` | Normalized metadata used for hashes/debug. |
| `content_sha256` | SHA-256 of raw layer content. |
| `hash` | SHA-256 of version, index, kind, role, content, metadata, and supplied id. |

## Debug output

Use `Tet.Prompt.debug/1` for structured data or `Tet.Prompt.debug_text/1` for a
stable line-oriented snapshot. Autosave checkpoints persist these debug
artifacts as produced by `Tet.Prompt` so restore fixtures can compare prompt
metadata, hashes, and attachment metadata without rebuilding history from vibes.

Debug output includes:

- prompt version, id, and prompt hash;
- layer count and message count;
- ordered layer index/kind/role/id;
- layer hash;
- raw content SHA-256 and byte count;
- redacted metadata.

Debug output deliberately does **not** include raw prompt content. Metadata keys
whose names look sensitive are redacted by the core `Tet.Redactor` helper and
replaced with `[REDACTED]`, including keys such as `api_key`, `apikey`,
`authorization`, `bearer`, `password`, `secret`, `token`, `*_token`,
`credential`, `private_key`, and `access_key`.

Example shape:

```text
tet.prompt.v1 id=prompt-... hash=...
layers=3 messages=3 metadata={"request_id":"req-1"}
000 system_base role=system id=layer-000-system_base-... hash=... content_sha256=... bytes=... metadata={"source":"system_base"}
001 project_rules role=system id=rules:project hash=... content_sha256=... bytes=... metadata={"source":"project"}
002 session_message role=user id=message:msg-1 hash=... content_sha256=... bytes=... metadata={"message_id":"msg-1","session_id":"ses-1","timestamp":"2025-01-01T00:00:00.000Z"}
```

Snapshot-style tests in `apps/tet_core/test/tet/prompt_test.exs` pin the debug
text, layer order, stable hashes, and redaction behavior.

## Boundary notes

- The contract lives in `tet_core` because it is pure data validation and
  deterministic transformation.
- Runtime session UX is unchanged by default; existing `%Tet.Message{}` values are consumed
  as session message layers without changing resume behavior.
- When runtime or autosave opts into `Tet.Compaction`, retained original messages
  are supplied as session message layers and generated compaction metadata is
  supplied as a `compaction_metadata` layer, so prompt debug can show the split
  without making the summary message part of durable session truth.
- Provider adapters remain free to convert `Tet.Prompt.to_provider_messages/1`
  into whatever request shape their APIs require.
- Autosave restore uses `Tet.Prompt.attachment_metadata/1` to persist normalized
  attachment metadata separately from the redacted debug artifact.
- Prompt Lab (`Tet.PromptLab`) is a neighboring advisory contract: it refines
  prompt text and stores Prompt Lab history, but it does not change prompt layer
  ordering, execute tools, call providers, or append chat messages.
- No provider credentials or raw attachment bytes belong in prompt debug output.
