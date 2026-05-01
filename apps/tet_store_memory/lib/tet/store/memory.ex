defmodule Tet.Store.Memory do
  @moduledoc """
  In-memory reference store adapter for BD-0034.

  All data lives in an Agent process, making this adapter suitable for testing
  and development. Data is lost when the process terminates — domain truth lives
  here only for the lifetime of the process (§04: domain truth is persistent).

  This adapter implements every `Tet.Store` callback so that contract tests can
  validate the same behaviour across both Memory and SQLite adapters.
  """

  @behaviour Tet.Store

  # -- Internal state structure --
  #
  # %{
  #   events: %{session_id => [Tet.Event.persisted_t()]},
  #   event_seq: %{session_id => non_neg_integer()},
  #   artifacts: %{id => Tet.ShellPolicy.Artifact.t()},
  #   checkpoints: %{id => Tet.Checkpoint.t()},
  #   errors: %{id => Tet.ErrorLog.t()},
  #   repairs: %{id => Tet.Repair.t()},
  #   workflows: %{id => Tet.Workflow.t()},
  #   workflow_steps: %{workflow_id => [Tet.WorkflowStep.t()]},
  #   messages: %{session_id => [Tet.Message.t()]},
  #   autosaves: %{session_id => [Tet.Autosave.t()]},
  #   prompt_history: [Tet.PromptLab.HistoryEntry.t()],
  #   workspaces: %{id => map()},
  #   sessions: %{id => map()},
  #   tasks: %{id => map()},
  #   tool_runs: %{id => map()},
  #   approvals: %{id => map()}
  # }

  @initial_state %{
    events: %{},
    event_seq: %{},
    artifacts: %{},
    checkpoints: %{},
    errors: %{},
    repairs: %{},
    workflows: %{},
    workflow_steps: %{},
    messages: %{},
    autosaves: %{},
    prompt_history: [],
    workspaces: %{},
    sessions: %{},
    tasks: %{},
    tool_runs: %{},
    approvals: %{}
  }

  @doc "Starts the in-memory store as an Agent for testing."
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Agent.start_link(fn -> @initial_state end, name: name)
  end

  @doc "Resets the store to its initial empty state."
  @spec reset(atom() | pid()) :: :ok
  def reset(server \\ __MODULE__) do
    Agent.update(server, fn _state -> @initial_state end)
  end

  @doc "Returns the full internal state (for debugging/inspection only)."
  @spec dump(atom() | pid()) :: map()
  def dump(server \\ __MODULE__) do
    Agent.get(server, & &1)
  end

  @doc "Stops the in-memory store agent."
  @spec stop(atom() | pid()) :: :ok
  def stop(server \\ __MODULE__) do
    case Process.whereis(server) do
      nil -> :ok
      _pid -> Agent.stop(server)
    end
  end

  # -- Tet.Store behaviour implementations --

  @impl true
  def boundary do
    %{
      application: :tet_store_memory,
      adapter: __MODULE__,
      status: :in_memory,
      format: :ets
    }
  end

  @impl true
  def health(_opts) do
    {:ok, %{application: :tet_store_memory, adapter: __MODULE__, status: :ok}}
  end

  @impl true
  def transaction(fun) when is_function(fun, 0) do
    # In-memory adapter: single-process, no real transaction semantics needed.
    try do
      case fun.() do
        {:ok, value} -> {:ok, value}
        {:error, reason} -> {:error, reason}
        value -> {:ok, value}
      end
    rescue
      exception -> {:error, {:caught, :error, exception}}
    end
  end

  # -- Workspace --

  @impl true
  def create_workspace(attrs), do: create_in(:workspaces, attrs, "ws_")

  @impl true
  def get_workspace(id), do: get_from(:workspaces, id)

  @impl true
  def set_trust(id, trust_state) do
    update_in_store(:workspaces, id, fn workspace ->
      {:ok, Map.put(workspace, :trust_state, trust_state)}
    end)
  end

  # -- Session --

  @impl true
  def create_session(attrs) when is_map(attrs) do
    with {:ok, session} <- Tet.Session.new(attrs) do
      Agent.update(__MODULE__, fn state ->
        put_in(state, [:sessions, session.id], session)
      end)

      {:ok, session}
    end
  end

  @impl true
  def update_session(id, attrs) do
    update_in_store(:sessions, id, fn session ->
      merged = Map.merge(session, attrs)
      {:ok, merged}
    end)
  end

  @impl true
  def get_session(id), do: get_from(:sessions, id)

  @impl true
  def list_sessions(_workspace_id) do
    sessions = Agent.get(__MODULE__, fn state -> Map.values(state.sessions) end)
    {:ok, sessions}
  end

  @impl true
  def list_sessions_with_opts(_opts), do: list_sessions(nil)

  # -- Task --

  @impl true
  def create_task(_attrs), do: {:error, {:not_implemented, :create_task}}

  # -- Messages --

  @impl true
  def append_message(attrs) when is_map(attrs) do
    with {:ok, message} <- Tet.Message.new(attrs) do
      Agent.update(__MODULE__, fn state ->
        messages = Map.get(state.messages, message.session_id, [])
        put_in(state, [:messages, message.session_id], messages ++ [message])
      end)

      {:ok, message}
    end
  end

  @impl true
  def save_message(%Tet.Message{} = message, _opts) do
    Agent.update(__MODULE__, fn state ->
      messages = Map.get(state.messages, message.session_id, [])
      put_in(state, [:messages, message.session_id], messages ++ [message])
    end)

    {:ok, message}
  end

  @impl true
  def list_messages(session_id, _opts) do
    messages = Agent.get(__MODULE__, fn state -> Map.get(state.messages, session_id, []) end)
    {:ok, messages}
  end

  # -- Tool runs --

  @impl true
  def record_tool_run(_attrs), do: {:error, {:not_implemented, :record_tool_run}}

  @impl true
  def update_tool_run(_id, _attrs), do: {:error, {:not_implemented, :update_tool_run}}

  # -- Approvals --

  @impl true
  def create_approval(_attrs), do: {:error, {:not_implemented, :create_approval}}

  @impl true
  def resolve_approval(_id, _resolution, _attrs),
    do: {:error, {:not_implemented, :resolve_approval}}

  @impl true
  def get_approval(_id), do: {:error, {:not_implemented, :get_approval}}

  @impl true
  def list_approvals(_session_id, _opts), do: {:error, {:not_implemented, :list_approvals}}

  # -- Compatibility --

  @impl true
  def fetch_session(session_id, _opts), do: get_session(session_id)

  @impl true
  def save_autosave(%Tet.Autosave{} = autosave, _opts) do
    Agent.update(__MODULE__, fn state ->
      autosaves = Map.get(state.autosaves, autosave.session_id, [])
      put_in(state, [:autosaves, autosave.session_id], autosaves ++ [autosave])
    end)

    {:ok, autosave}
  end

  @impl true
  def load_autosave(session_id, _opts) do
    autosaves =
      Agent.get(__MODULE__, fn state -> Map.get(state.autosaves, session_id, []) end)

    case List.last(autosaves) do
      nil -> {:error, :autosave_not_found}
      autosave -> {:ok, autosave}
    end
  end

  @impl true
  def list_autosaves(_opts) do
    autosaves =
      Agent.get(__MODULE__, fn state ->
        state.autosaves
        |> Map.values()
        |> List.flatten()
      end)

    {:ok, autosaves}
  end

  @impl true
  def save_event(%Tet.Event{} = event, _opts) do
    {:ok, event}
  end

  @impl true
  def list_events(session_id, _opts) do
    events =
      Agent.get(__MODULE__, fn state -> Map.get(state.events, session_id, []) end)

    {:ok, events}
  end

  @impl true
  def emit_event(attrs) when is_map(attrs) do
    append_event(attrs, [])
  end

  @impl true
  def save_prompt_history(%Tet.PromptLab.HistoryEntry{} = history, _opts) do
    Agent.update(__MODULE__, fn state ->
      put_in(state, [:prompt_history], state.prompt_history ++ [history])
    end)

    {:ok, history}
  end

  @impl true
  def list_prompt_history(_opts) do
    history = Agent.get(__MODULE__, fn state -> state.prompt_history end)
    {:ok, history}
  end

  @impl true
  def fetch_prompt_history(history_id, _opts) do
    history = Agent.get(__MODULE__, fn state -> state.prompt_history end)

    case Enum.find(history, &(&1.id == history_id)) do
      nil -> {:error, :prompt_history_not_found}
      entry -> {:ok, entry}
    end
  end

  # -- BD-0034: Event Log --

  @impl true
  def append_event(attrs, _opts) when is_map(attrs) do
    with {:ok, event} <- Tet.Event.new(attrs) do
      event = assign_sequence(event)

      Agent.update(__MODULE__, fn state ->
        events = Map.get(state.events, event.session_id, [])
        put_in(state, [:events, event.session_id], events ++ [event])
      end)

      {:ok, event}
    end
  end

  @impl true
  def get_event(event_id, _opts) when is_binary(event_id) do
    events =
      Agent.get(__MODULE__, fn state ->
        state.events
        |> Map.values()
        |> List.flatten()
      end)

    case Enum.find(events, &(&1.id == event_id)) do
      nil -> {:error, :event_not_found}
      event -> {:ok, event}
    end
  end

  # -- BD-0034: Artifacts --

  @impl true
  def create_artifact(attrs, _opts) when is_map(attrs) do
    with {:ok, artifact} <- Tet.ShellPolicy.Artifact.new(attrs) do
      Agent.update(__MODULE__, fn state ->
        put_in(state, [:artifacts, artifact.id], artifact)
      end)

      {:ok, artifact}
    end
  end

  @impl true
  def get_artifact(artifact_id, _opts) when is_binary(artifact_id) do
    case Agent.get(__MODULE__, fn state -> Map.get(state.artifacts, artifact_id) end) do
      nil -> {:error, :artifact_not_found}
      artifact -> {:ok, artifact}
    end
  end

  @impl true
  def list_artifacts(session_id, _opts) when is_binary(session_id) do
    artifacts =
      Agent.get(__MODULE__, fn state -> Map.values(state.artifacts) end)

    filtered =
      Enum.filter(artifacts, fn artifact ->
        artifact.session_id == session_id or
          artifact.task_id == session_id or
          artifact.tool_call_id == session_id
      end)

    {:ok, filtered}
  end

  # -- BD-0034: Checkpoints --

  @impl true
  def save_checkpoint(attrs, _opts) when is_map(attrs) do
    with {:ok, checkpoint} <- Tet.Checkpoint.new(attrs) do
      Agent.update(__MODULE__, fn state ->
        put_in(state, [:checkpoints, checkpoint.id], checkpoint)
      end)

      {:ok, checkpoint}
    end
  end

  @impl true
  def get_checkpoint(checkpoint_id, _opts) when is_binary(checkpoint_id) do
    case Agent.get(__MODULE__, fn state -> Map.get(state.checkpoints, checkpoint_id) end) do
      nil -> {:error, :checkpoint_not_found}
      checkpoint -> {:ok, checkpoint}
    end
  end

  @impl true
  def list_checkpoints(session_id, _opts) when is_binary(session_id) do
    checkpoints =
      Agent.get(__MODULE__, fn state ->
        state.checkpoints
        |> Map.values()
        |> Enum.filter(&(&1.session_id == session_id))
      end)

    {:ok, checkpoints}
  end

  @impl true
  def delete_checkpoint(checkpoint_id, _opts) when is_binary(checkpoint_id) do
    Agent.update(__MODULE__, fn state ->
      {_, new_state} = pop_in(state, [:checkpoints, checkpoint_id])
      new_state
    end)

    {:ok, :ok}
  end

  # -- BD-0034: Workflow Steps --

  @impl true
  def append_step(attrs, _opts) when is_map(attrs) do
    with {:ok, step} <- Tet.WorkflowStep.new(attrs) do
      Agent.update(__MODULE__, fn state ->
        steps = Map.get(state.workflow_steps, step.workflow_id, [])
        put_in(state, [:workflow_steps, step.workflow_id], steps ++ [step])
      end)

      {:ok, step}
    end
  end

  @impl true
  def get_steps(session_id, _opts) when is_binary(session_id) do
    steps =
      Agent.get(__MODULE__, fn state ->
        state.workflow_steps
        |> Map.values()
        |> List.flatten()
        |> Enum.filter(&(&1.session_id == session_id))
      end)

    {:ok, steps}
  end

  # -- BD-0034: Error Log --

  @impl true
  def log_error(attrs, _opts) when is_map(attrs) do
    with {:ok, error_entry} <- Tet.ErrorLog.new(attrs) do
      Agent.update(__MODULE__, fn state ->
        put_in(state, [:errors, error_entry.id], error_entry)
      end)

      {:ok, error_entry}
    end
  end

  @impl true
  def list_errors(session_id, _opts) when is_binary(session_id) do
    errors =
      Agent.get(__MODULE__, fn state ->
        state.errors
        |> Map.values()
        |> Enum.filter(&(&1.session_id == session_id))
      end)

    {:ok, errors}
  end

  @impl true
  def get_error(error_id, _opts) when is_binary(error_id) do
    case Agent.get(__MODULE__, fn state -> Map.get(state.errors, error_id) end) do
      nil -> {:error, :error_not_found}
      error_entry -> {:ok, error_entry}
    end
  end

  @impl true
  def resolve_error(error_id, _opts) when is_binary(error_id) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state.errors, error_id) do
        nil ->
          {{:error, :error_not_found}, state}

        error_entry ->
          resolved_at = DateTime.utc_now() |> DateTime.to_iso8601()
          resolved = Tet.ErrorLog.resolve(error_entry, resolved_at)
          new_state = put_in(state, [:errors, error_id], resolved)
          {{:ok, resolved}, new_state}
      end
    end)
  end

  # -- BD-0034: Repair Queue --

  @impl true
  def enqueue_repair(attrs, _opts) when is_map(attrs) do
    with {:ok, repair} <- Tet.Repair.new(attrs) do
      Agent.update(__MODULE__, fn state ->
        put_in(state, [:repairs, repair.id], repair)
      end)

      {:ok, repair}
    end
  end

  @impl true
  def dequeue_repair(_opts) do
    Agent.get_and_update(__MODULE__, fn state ->
      pending =
        state.repairs
        |> Map.values()
        |> Enum.filter(&(&1.status == :pending))
        |> Enum.sort_by(& &1.created_at)

      case pending do
        [] ->
          {{:ok, nil}, state}

        [%Tet.Repair{} = repair | _rest] ->
          updated_at = DateTime.utc_now() |> DateTime.to_iso8601()
          in_progress = %{repair | status: :in_progress, updated_at: updated_at}
          new_state = put_in(state, [:repairs, repair.id], in_progress)
          {{:ok, in_progress}, new_state}
      end
    end)
  end

  @impl true
  def update_repair(repair_id, attrs, _opts)
      when is_binary(repair_id) and is_map(attrs) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state.repairs, repair_id) do
        nil ->
          {{:error, :repair_not_found}, state}

        repair ->
          updated_at = DateTime.utc_now() |> DateTime.to_iso8601()
          updated = merge_repair_attrs(repair, attrs, updated_at)
          new_state = put_in(state, [:repairs, repair_id], updated)
          {{:ok, updated}, new_state}
      end
    end)
  end

  @impl true
  def list_repairs(opts) when is_list(opts) do
    session_id = Keyword.get(opts, :session_id)
    status = Keyword.get(opts, :status)

    repairs =
      Agent.get(__MODULE__, fn state -> Map.values(state.repairs) end)
      |> maybe_filter_by_session(session_id)
      |> maybe_filter_by_status(status)

    {:ok, repairs}
  end

  # -- Workflow (required behaviour) --

  @impl true
  def create_workflow(attrs) when is_map(attrs) do
    with {:ok, workflow} <- Tet.Workflow.new(attrs) do
      Agent.update(__MODULE__, fn state ->
        put_in(state, [:workflows, workflow.id], workflow)
      end)

      {:ok, workflow}
    end
  end

  @impl true
  def update_workflow_status(id, status) do
    update_in_store(:workflows, id, fn workflow ->
      {:ok, %{workflow | status: status}}
    end)
  end

  @impl true
  def get_workflow(id), do: get_from(:workflows, id)

  @impl true
  def start_step(_attrs), do: {:error, {:not_implemented, :start_step}}

  @impl true
  def commit_step(_id, _output), do: {:error, {:not_implemented, :commit_step}}

  @impl true
  def fail_step(_id, _error), do: {:error, {:not_implemented, :fail_step}}

  @impl true
  def cancel_step(_id), do: {:error, {:not_implemented, :cancel_step}}

  @impl true
  def list_pending_workflows do
    workflows =
      Agent.get(__MODULE__, fn state ->
        state.workflows
        |> Map.values()
        |> Enum.filter(&(&1.status in [:created, :running, :paused_for_approval]))
      end)

    {:ok, workflows}
  end

  @impl true
  def list_steps(workflow_id) do
    steps = Agent.get(__MODULE__, fn state -> Map.get(state.workflow_steps, workflow_id, []) end)
    {:ok, steps}
  end

  @impl true
  def claim_workflow(_id, _node, _ttl), do: {:ok, :claimed}

  # -- Private helpers --

  defp assign_sequence(%Tet.Event{} = event) do
    session_id = event.session_id || "global"

    Agent.update(__MODULE__, fn state ->
      current = Map.get(state.event_seq, session_id, 0)
      put_in(state, [:event_seq, session_id], current + 1)
    end)

    seq_val =
      Agent.get(__MODULE__, fn state ->
        Map.get(state.event_seq, session_id, 0)
      end)

    %Tet.Event{event | sequence: seq_val, seq: seq_val}
  end

  defp get_from(collection, id) do
    case Agent.get(__MODULE__, fn state -> get_in(state, [collection, id]) end) do
      nil -> {:error, {:not_found, collection, id}}
      value -> {:ok, value}
    end
  end

  defp create_in(collection, attrs, _prefix) do
    id = Map.get(attrs, :id) || Map.get(attrs, "id") || generate_id()

    entry = Map.put(attrs, :id, id)

    Agent.update(__MODULE__, fn state ->
      put_in(state, [collection, id], entry)
    end)

    {:ok, entry}
  end

  defp update_in_store(collection, id, update_fn) do
    Agent.get_and_update(__MODULE__, fn state ->
      case get_in(state, [collection, id]) do
        nil ->
          {{:error, {:not_found, collection, id}}, state}

        current ->
          case update_fn.(current) do
            {:ok, updated} ->
              new_state = put_in(state, [collection, id], updated)
              {{:ok, updated}, new_state}

            {:error, reason} ->
              {{:error, reason}, state}
          end
      end
    end)
  end

  defp maybe_filter_by_session(repairs, nil), do: repairs

  defp maybe_filter_by_session(repairs, session_id) do
    Enum.filter(repairs, &(&1.session_id == session_id))
  end

  defp maybe_filter_by_status(repairs, nil), do: repairs

  defp maybe_filter_by_status(repairs, status) do
    Enum.filter(repairs, &(&1.status == status))
  end

  defp merge_repair_attrs(%Tet.Repair{} = repair, attrs, updated_at) do
    %{
      repair
      | status: Map.get(attrs, :status, Map.get(attrs, "status", repair.status)),
        result: Map.get(attrs, :result, Map.get(attrs, "result", repair.result)),
        description:
          Map.get(attrs, :description, Map.get(attrs, "description", repair.description)),
        context: Map.get(attrs, :context, Map.get(attrs, "context", repair.context)),
        updated_at: updated_at
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
