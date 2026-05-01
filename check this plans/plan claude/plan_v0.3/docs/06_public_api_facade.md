# 06 — Public API Facade

## Placement

The public facade lives in runtime:

```text
apps/tet_runtime/lib/tet.ex
```

It delegates to runtime internals, so it must not live in `tet_core`. `tet_core` remains pure and does not reference runtime modules.

## Contract

All user interfaces call this module and no deeper module.

```elixir
defmodule Tet do
  @moduledoc "Public Tet API used by CLI, optional Phoenix, tests, and future adapters."

  alias Tet.{Workspace, Session, Approval, Event}

  # workspace
  @spec init_workspace(binary(), keyword()) :: {:ok, Workspace.t()} | {:error, term()}
  def init_workspace(path, opts \\ []), do: Tet.Runtime.init_workspace(path, opts)

  @spec trust_workspace(binary(), keyword()) :: {:ok, Workspace.t()} | {:error, term()}
  def trust_workspace(ref, opts \\ []), do: Tet.Runtime.trust_workspace(ref, opts)

  @spec get_workspace(binary()) :: {:ok, Workspace.t()} | {:error, term()}
  def get_workspace(ref), do: Tet.Runtime.get_workspace(ref)

  # sessions
  @spec start_session(binary(), keyword()) :: {:ok, Session.t()} | {:error, term()}
  def start_session(workspace_ref, opts \\ []), do: Tet.Runtime.start_session(workspace_ref, opts)

  @spec list_sessions(binary(), keyword()) :: {:ok, [Session.t()]} | {:error, term()}
  def list_sessions(workspace_ref, opts \\ []), do: Tet.Runtime.list_sessions(workspace_ref, opts)

  @spec get_session(binary()) :: {:ok, Session.t()} | {:error, term()}
  def get_session(session_id), do: Tet.Runtime.get_session(session_id)

  # prompts
  @spec send_prompt(binary(), binary(), keyword()) :: :ok | {:error, term()}
  def send_prompt(session_id, prompt, opts \\ []) do
    Tet.Runtime.dispatch(session_id, %Tet.Command.UserPrompt{text: prompt, opts: Map.new(opts)})
  end

  # approvals
  @spec list_approvals(binary(), keyword()) :: {:ok, [Approval.t()]} | {:error, term()}
  def list_approvals(session_id, filter \\ [status: :pending]) do
    Tet.Runtime.list_approvals(session_id, filter)
  end

  @spec approve_patch(binary(), binary(), keyword()) :: :ok | {:error, term()}
  def approve_patch(session_id, approval_id, opts \\ []) do
    Tet.Runtime.dispatch(session_id, %Tet.Command.PatchDecision{
      approval_id: approval_id,
      decision: :approve,
      opts: Map.new(opts)
    })
  end

  @spec reject_patch(binary(), binary(), keyword()) :: :ok | {:error, term()}
  def reject_patch(session_id, approval_id, opts \\ []) do
    Tet.Runtime.dispatch(session_id, %Tet.Command.PatchDecision{
      approval_id: approval_id,
      decision: :reject,
      opts: Map.new(opts)
    })
  end

  # verification
  @spec run_verification(binary(), binary(), keyword()) :: :ok | {:error, term()}
  def run_verification(session_id, verifier_name, opts \\ []) do
    Tet.Runtime.dispatch(session_id, %Tet.Command.RunVerification{
      name: verifier_name,
      opts: Map.new(opts)
    })
  end

  # events
  @spec subscribe(binary()) :: :ok | {:error, term()}
  def subscribe(session_id), do: Tet.Runtime.subscribe(session_id)

  @spec unsubscribe(binary()) :: :ok
  def unsubscribe(session_id), do: Tet.Runtime.unsubscribe(session_id)

  @spec list_events(binary(), keyword()) :: {:ok, [Event.t()]} | {:error, term()}
  def list_events(session_id, opts \\ []), do: Tet.Runtime.list_events(session_id, opts)

  # helpers
  @spec lookup(:session | :approval | :artifact | :task, binary(), keyword()) ::
          {:ok, binary()} | {:error, :not_found}
  def lookup(kind, short_id, opts \\ []), do: Tet.Runtime.lookup(kind, short_id, opts)

  @spec prompt_debug(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def prompt_debug(session_id, opts \\ []), do: Tet.Runtime.prompt_debug(session_id, opts)

  @spec doctor(binary() | nil) :: {:ok, map()} | {:error, term()}
  def doctor(workspace_ref \\ nil), do: Tet.Runtime.doctor(workspace_ref)
end
```

## Command structs

These live in `tet_core`:

```elixir
defmodule Tet.Command do
  defmodule UserPrompt do
    @enforce_keys [:text]
    defstruct [:text, opts: %{}]
  end

  defmodule PatchDecision do
    @enforce_keys [:approval_id, :decision]
    defstruct [:approval_id, :decision, opts: %{}]
  end

  defmodule RunVerification do
    @enforce_keys [:name]
    defstruct [:name, opts: %{}]
  end

  defmodule SetMode do
    @enforce_keys [:mode]
    defstruct [:mode]
  end

  defmodule Cancel do
    @enforce_keys [:reason]
    defstruct [:reason]
  end
end
```

## Subscription model

`Tet.subscribe/1` registers the caller for `%Tet.Event{}` messages for the session.

```elixir
:ok = Tet.subscribe(session_id)

receive do
  %Tet.Event{type: :provider.text_delta, payload: %{text: t}} -> IO.write(t)
  %Tet.Event{type: :approval.created, payload: %{id: id}} -> render_approval(id)
  %Tet.Event{type: :patch.applied} -> render_success()
end
```

Implementation uses `Tet.EventBus` in runtime. UIs call `Tet.subscribe/1`, not `Tet.EventBus.*` directly.

## What the facade hides

UIs must not name or call:

```text
Tet.Runtime.SessionRegistry
Tet.Runtime.SessionSupervisor
Tet.Runtime.SessionWorker
Tet.Agent.RuntimeSupervisor
Tet.Agent.Runtime
Tet.EventBus
Tet.Tool.Executor
Tet.Tool.Registry
Tet.Tools.*
Tet.Prompt.*
Tet.LLM.Providers.*
Tet.Store.Supervisor
Tet.Store.SQLite.Repo
```

If a UI needs data that the facade does not expose, add a small function to `Tet`, not a direct internal call.

## Compatibility rule

Inside a major version:

- adding functions is allowed;
- adding optional opts is allowed;
- adding event fields is allowed;
- removing functions is forbidden;
- changing return shapes is forbidden;
- removing required fields from events is forbidden.
