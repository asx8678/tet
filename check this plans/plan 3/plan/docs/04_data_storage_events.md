# 04 — Data, Storage, and Events

## Storage goal

The first version persists locally without Postgres, Phoenix, or any database server.

Default file:

```text
repo-root/.tet/tet.sqlite
```

All persistence goes through the `Tet.Store` behaviour defined in `tet_core`.

## Workspace layout

```text
repo-root/
  .tet/
    tet.sqlite
    config.toml
    prompts/
      system.md
      mode_chat.md
      mode_explore.md
      mode_execute.md
      tool_cards.md
    artifacts/
      diffs/
      stdout/
      stderr/
      file_snapshots/
      prompt_debug/
      provider_payload/
    cache/
```

Optional user defaults:

```text
~/.config/tet/config.toml
~/.local/share/tet/                 future cross-workspace index only
```

Workspace config wins over user config.

## Domain entities

All domain structs live in `tet_core`. SQLite/Postgres schemas map to/from these structs but do not become the domain model.

### `Tet.Workspace`

```text
id              uuid
name            string
root_path       canonical absolute path
tet_dir_path    defaults to <root_path>/.tet
trust_state     :untrusted | :trusted
created_at      DateTime
updated_at      DateTime
metadata        map
```

### `Tet.Session`

```text
id               uuid
workspace_id     uuid
short_id         s_<6 hex>
title            string | nil
mode             :chat | :explore | :execute
status           :idle | :running | :waiting_approval | :complete | :error
provider         string
model            string
active_task_id   uuid | nil
created_at       DateTime
updated_at       DateTime
metadata         map
```

### `Tet.Task`

```text
id            uuid
session_id    uuid
title         string
status        :active | :complete | :cancelled
created_at    DateTime
updated_at    DateTime
metadata      map
```

V1 allows one active task per session.

### `Tet.Message`

```text
id           uuid
session_id   uuid
role         :user | :assistant | :system | :tool
content      string
created_at   DateTime
metadata     map
```

Assistant streaming deltas are events; the final assistant response is persisted as one message.

### `Tet.ToolRun`

```text
id              uuid
session_id      uuid
task_id         uuid | nil
tool_name       string
read_or_write   :read | :write
args            map
status          :proposed | :blocked | :waiting_approval | :running | :success | :error
block_reason    atom | nil
changed_files   [string]
started_at      DateTime | nil
finished_at     DateTime | nil
metadata        map
```

Blocked tool calls are persisted.

### `Tet.Approval`

```text
id                  uuid
session_id          uuid
task_id             uuid | nil
tool_run_id         uuid
status              :pending | :approved | :rejected
reason              string
diff_artifact_id    uuid
resolved_at         DateTime | nil
created_at          DateTime
updated_at          DateTime
metadata            map
```

Rules:

- only one pending approval per session;
- approval is not patch application;
- rejected approval changes no files;
- approved patch must still apply cleanly before writing.

### `Tet.Artifact`

```text
id            uuid
session_id    uuid
kind          :diff | :stdout | :stderr | :file_snapshot | :prompt_debug | :provider_payload
content       binary | nil
path          string | nil
sha256        string
created_at    DateTime
metadata      map
```

Small artifacts can be stored inline. Large artifacts are stored under `.tet/artifacts/` and referenced by path + sha256.

### `Tet.Event`

```text
id           uuid
session_id   uuid
type         atom
payload      map
seq          monotonic integer per session
created_at   DateTime
```

V1 event types:

```text
workspace.created
workspace.trusted
session.created
session.status_changed
message.user.saved
message.assistant.saved
provider.started
provider.text_delta
provider.usage
provider.done
provider.error
tool.requested
tool.blocked
tool.started
tool.finished
approval.created
approval.approved
approval.rejected
artifact.created
patch.applied
patch.failed
verifier.started
verifier.finished
error.recorded
```

Events are a durable timeline, not a full event-sourcing system in v1.

## Store behaviour

```elixir
defmodule Tet.Store do
  @callback transaction((-> term())) :: {:ok, term()} | {:error, term()}

  @callback create_workspace(map()) :: {:ok, Tet.Workspace.t()} | {:error, term()}
  @callback get_workspace(binary()) :: {:ok, Tet.Workspace.t()} | {:error, term()}
  @callback set_trust(binary(), atom()) :: {:ok, Tet.Workspace.t()} | {:error, term()}

  @callback create_session(map()) :: {:ok, Tet.Session.t()} | {:error, term()}
  @callback update_session(binary(), map()) :: {:ok, Tet.Session.t()} | {:error, term()}
  @callback get_session(binary()) :: {:ok, Tet.Session.t()} | {:error, term()}
  @callback list_sessions(binary()) :: {:ok, [Tet.Session.t()]} | {:error, term()}

  @callback create_task(map()) :: {:ok, Tet.Task.t()} | {:error, term()}
  @callback append_message(map()) :: {:ok, Tet.Message.t()} | {:error, term()}

  @callback record_tool_run(map()) :: {:ok, Tet.ToolRun.t()} | {:error, term()}
  @callback update_tool_run(binary(), map()) :: {:ok, Tet.ToolRun.t()} | {:error, term()}

  @callback create_approval(map()) :: {:ok, Tet.Approval.t()} | {:error, term()}
  @callback resolve_approval(binary(), atom(), map()) :: {:ok, Tet.Approval.t()} | {:error, term()}
  @callback get_approval(binary()) :: {:ok, Tet.Approval.t()} | {:error, term()}
  @callback list_approvals(binary(), keyword()) :: {:ok, [Tet.Approval.t()]} | {:error, term()}

  @callback create_artifact(map()) :: {:ok, Tet.Artifact.t()} | {:error, term()}
  @callback get_artifact(binary()) :: {:ok, Tet.Artifact.t()} | {:error, term()}

  @callback emit_event(map()) :: {:ok, Tet.Event.t()} | {:error, term()}
  @callback list_events(binary(), keyword()) :: {:ok, [Tet.Event.t()]} | {:error, term()}
end
```

## Config file

`repo-root/.tet/config.toml`:

```toml
[workspace]
trusted = false

[provider]
name  = "primary"
model = "configured-model"

[verification]
default = "mix_test"

[verification.allowlist]
mix_format  = ["mix", "format"]
mix_test    = ["mix", "test"]
mix_compile = ["mix", "compile", "--warnings-as-errors"]
npm_test    = ["npm", "test"]
cargo_check = ["cargo", "check"]

[limits]
max_tool_iterations = 6
max_file_read_bytes = 262144
max_patch_bytes = 524288
verifier_timeout_ms = 60000
provider_timeout_ms = 120000
max_concurrent_tools = 4
```

Runtime config lives under `:tet_runtime`, not Phoenix.

## ID strategy

Use UUIDv4 primary keys and short ids for CLI display:

```text
session   s_8f3a21
approval  appr_9c10aa
artifact  art_3b1d77
task      t_a91f02
```

Short ids are unique per workspace. Lookups resolve `(kind, short_id, workspace_id)` to UUID.
