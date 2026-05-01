# 00 — Corrections to Existing Docs

Surgical fixes that should land before any new code is written. Each one
targets a specific landmine in the original plan.

> **v0.3 changelog:** the `Tet.Codec` example in v0.2 used `unquote/1`
> at module top-level, which does not compile. The version below spells
> out the encoders explicitly. The per-path trust example was also
> mixing globs and exact paths inconsistently; clarified.

## §1 — Atom encoding across storage boundaries

**Problem.** Several core structs use atoms for status fields
(`Tet.Session.mode`, `Tet.Session.status`, `Tet.ToolRun.status`,
`Tet.Approval.status`, `Tet.Artifact.kind`, `Tet.Event.type`,
`Workspace.trust_state`). SQLite stores them as strings.
`String.to_atom/1` on read is unsafe (atom table leak, DoS), and
`String.to_existing_atom/1` fails when modules defining the atom
haven't been loaded — which happens during early supervisor boot and
during release upgrades.

**Fix.** Add `Tet.Codec` to `tet_core` with explicit allowlists. Spell
the functions out — meta-generation via `for ... do def unquote(fun)`
is invalid at module top level (`unquote/1` requires a `quote` context).

```elixir
defmodule Tet.Codec do
  @session_modes ~w(chat explore execute)a
  @session_statuses ~w(idle running waiting_approval complete error)a
  @tool_run_statuses ~w(proposed blocked waiting_approval running success error)a
  @approval_statuses ~w(pending approved rejected)a
  @artifact_kinds ~w(diff stdout stderr file_snapshot prompt_debug provider_payload)a
  @trust_states ~w(untrusted trusted)a
  @workflow_statuses ~w(running paused_for_approval completed failed cancelled)a
  @workflow_step_statuses ~w(started committed failed cancelled)a

  @event_types_workflow ~w(
    workflow.step_started workflow.step_committed workflow.step_failed
    workflow.cancelled workflow.resumed
    provider.started provider.text_delta provider.usage provider.done provider.error
    tool.requested tool.blocked tool.started tool.finished
    approval.created approval.approved approval.rejected
    artifact.created
    patch.applied patch.failed patch.rolled_back
    verifier.started verifier.finished
    message.user.saved message.assistant.saved
  )a

  @event_types_domain ~w(
    workspace.created workspace.trusted workspace.migrated
    session.created session.status_changed session.truncated
    error.recorded
  )a

  @event_types @event_types_workflow ++ @event_types_domain

  # Encoders never raise on a known atom.
  def encode_session_mode(m) when m in @session_modes, do: Atom.to_string(m)
  def encode_session_status(s) when s in @session_statuses, do: Atom.to_string(s)
  def encode_tool_run_status(s) when s in @tool_run_statuses, do: Atom.to_string(s)
  def encode_approval_status(s) when s in @approval_statuses, do: Atom.to_string(s)
  def encode_artifact_kind(k) when k in @artifact_kinds, do: Atom.to_string(k)
  def encode_trust_state(t) when t in @trust_states, do: Atom.to_string(t)
  def encode_workflow_status(s) when s in @workflow_statuses, do: Atom.to_string(s)
  def encode_workflow_step_status(s) when s in @workflow_step_statuses, do: Atom.to_string(s)
  def encode_event_type(t) when t in @event_types, do: Atom.to_string(t)

  # Decoders raise on unknown input.
  def decode_session_mode(s), do: lookup!(@session_modes, s, "session mode")
  def decode_session_status(s), do: lookup!(@session_statuses, s, "session status")
  def decode_tool_run_status(s), do: lookup!(@tool_run_statuses, s, "tool run status")
  def decode_approval_status(s), do: lookup!(@approval_statuses, s, "approval status")
  def decode_artifact_kind(s), do: lookup!(@artifact_kinds, s, "artifact kind")
  def decode_trust_state(s), do: lookup!(@trust_states, s, "trust state")
  def decode_workflow_status(s), do: lookup!(@workflow_statuses, s, "workflow status")
  def decode_workflow_step_status(s), do: lookup!(@workflow_step_statuses, s, "workflow step status")
  def decode_event_type(s), do: lookup!(@event_types, s, "event type")

  defp lookup!(allow, string, label) when is_binary(string) do
    case Enum.find(allow, fn a -> Atom.to_string(a) == string end) do
      nil -> raise ArgumentError, "unknown #{label}: #{inspect(string)}"
      atom -> atom
    end
  end

  # For grep-able exhaustiveness in tests.
  def all_event_types, do: @event_types
  def workflow_event_types, do: @event_types_workflow
  def domain_event_types, do: @event_types_domain
end
```

Store adapters MUST use `Tet.Codec.encode_*/1` on write and
`decode_*/1` on read. No use of `String.to_atom/1` or
`String.to_existing_atom/1` is allowed in store adapters; this is
enforced by `tools/check_imports.sh`.

Also: bump `Tet.Store` behaviour with
`@callback schema_version() :: integer()`. `tet doctor` checks the
live schema version against the code's expected version and refuses
to start the runtime on mismatch (clear error message + a
`tet migrate` hint).

## §2 — `Tet.cancel/2` is missing from the facade

**Problem.** `Tet.Command.Cancel` exists in core, but the facade has no
function to send it.

**Fix.** Add to `apps/tet_runtime/lib/tet.ex`:

```elixir
@spec cancel(binary(), atom() | binary(), keyword()) :: :ok | {:error, term()}
def cancel(session_id, reason \\ :user_cancelled, opts \\ []) do
  Tet.Runtime.dispatch(session_id, %Tet.Command.Cancel{
    reason: reason,
    opts: Map.new(opts)
  })
end
```

Cancellation semantics live in `upgrades/12_durable_execution.md`. The
facade entry point gives CLI Ctrl-C, LiveView "stop" buttons, and
external timeouts a uniform way to request cancellation.

CLI: `tet cancel SESSION_ID [--force]` with exit code 0 on success.

## §3 — Patch application must be atomic

The detailed atomic-apply algorithm and rollback-per-change-type rules
live in `upgrades/12_durable_execution.md` §"Patch application." This
doc only records the inline correction:

- Replace "snapshot changed files when practical" with mandatory atomic
  apply.
- Default applier is plain `git apply` (working tree only). `--index`
  is an opt-in config flag (`[execute].apply_to_index = true`).
  Applying to the index when the user has unrelated staged changes
  causes spurious failures and is the wrong default.
- Rollback is mandatory and is per-change-type (create / delete /
  modify / rename / mode-change). See doc 12.
- `git >= 2.20` enforced by `tet doctor`.
- Line-ending normalization is the user's responsibility via
  `.gitattributes`. The applier never silently rewrites line endings.

## §4 — Per-path trust granularity

**Problem.** `Workspace.trust_state` is binary
(`:untrusted` | `:trusted`). A user editing a Phoenix app may want to
allow writes under `lib/` and `test/` but never under
`config/runtime.exs` or `priv/secrets/`.

**Fix.** Replace the binary trust state with path-glob lists. Always
use globs (relative to workspace root); exact paths are expressed as
themselves (no wildcards). `.gitignore`-style syntax: `**` matches any
number of directories, `*` does not cross `/`, trailing `/` matches
directories only.

```elixir
defmodule Tet.Workspace.Trust do
  @type t :: %__MODULE__{
    state: :untrusted | :trusted,
    allow_globs: [String.t()],   # relative to workspace root
    deny_globs:  [String.t()]    # always wins over allow
  }
  defstruct state: :untrusted, allow_globs: ["**"], deny_globs: []
end
```

Default trust on `tet init --trust` is equivalent to the original
binary `:trusted`:
`state: :trusted, allow_globs: ["**"], deny_globs: []`. Users tighten
via:

```bash
tet workspace trust . \
  --allow "lib/**" --allow "test/**" \
  --deny "config/runtime.exs" --deny "priv/secrets/**"
```

`Tet.Policy.PathPolicy` consults trust globs after the existing
canonical-path/symlink-escape checks. New reason atom:
`:path_denied_by_trust`. The original binary trust check still exists
(rejecting writes when `state: :untrusted`); the per-path layer is
additive.

Glob matching uses `:filelib.wildcard/1` semantics for portability.
Property tests (§5) cover edge cases.

## §5 — Property and fuzz tests

The unified test pyramid lives in `upgrades/18_test_strategy.md`. The
non-negotiable additions, summarized:

- **Property tests** (`stream_data`):
  - `Tet.Codec` round-trip across every allowlisted atom.
  - `Tet.Patch.Approval` state-machine: only legal transitions reach
    legal states.
  - `Tet.Workflow` replay determinism.
  - Trust-glob matcher: `deny_globs` always wins over `allow_globs`.
  - `Tet.Ids` short-id collision over N=10_000 generations.
- **Fuzz tests**:
  - Path resolver: 10_000 random paths mixing `..`, symlinks, NUL
    bytes, percent-encoding, Windows separators, long components, case
    variants.
  - Unified-diff parser: malformed inputs (truncated headers,
    mismatched hunks, binary preludes, mixed line endings).

Acceptance gains a line:

- [ ] Path resolver and approval state machine pass property/fuzz suites.
