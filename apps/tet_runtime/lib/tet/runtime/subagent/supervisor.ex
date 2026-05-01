defmodule Tet.Runtime.Subagent.Supervisor do
  @moduledoc """
  DynamicSupervisor managing subagent worker processes with bounded concurrency.

  Subagents are isolated GenServer workers that each run one subagent task.
  The supervisor enforces a configurable max worker count and provides
  lifecycle operations: start, cancel, list, and count.

  ## Bounded concurrency

  The max worker count is read from application config:

      config :tet_runtime, :subagent_max_workers, 5

  Default is 5. When the limit is reached, `start_subagent/1` returns
  `{:error, :max_workers_reached}`.

  ## Parent-task correlation

  Each subagent carries a `parent_task_id` in its spec. Use
  `list_subagents/1` with a task id to find all subagents for a task, or
  `cancel_by_task/1` to cancel all subagents for a task.

  ## Supervision

  Workers use `restart: :transient` — they are not restarted on normal exit,
  only on abnormal crashes.
  """

  use DynamicSupervisor

  @name Tet.Runtime.Subagent.Supervisor

  @default_max_workers 5

  @doc "Returns the supervisor atom registered in the supervision tree."
  def name, do: @name

  @doc "Starts the Subagent Supervisor."
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: @name)
  end

  @impl true
  def init(opts) do
    max_children = opts[:max_children] || max_workers()

    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 5,
      max_children: max_children
    )
  end

  @doc """
  Returns the configured max number of concurrent subagent workers.

  Reads from `Application.get_env(:tet_runtime, :subagent_max_workers)` with
  a default of 5.
  """
  @spec max_workers() :: pos_integer()
  def max_workers do
    Application.get_env(:tet_runtime, :subagent_max_workers, @default_max_workers)
  end

  @doc """
  Starts a subagent worker under this supervisor.

  Validates the spec first. If the current worker count is at the max,
  returns `{:error, :max_workers_reached}`. If a subagent with the same
  id is already running, returns `{:error, :already_started}`.

  Returns `{:ok, pid}` or `{:error, reason}`.
  """
  @spec start_subagent(Tet.Subagent.Spec.t()) ::
          DynamicSupervisor.on_start_child() | {:error, term()}
  def start_subagent(%Tet.Subagent.Spec{} = spec) do
    subagent_id = Tet.Subagent.Spec.subagent_id(spec)

    case find_subagent(subagent_id) do
      nil ->
        case DynamicSupervisor.start_child(
               @name,
               {Tet.Runtime.Subagent.Worker, spec}
             ) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, :max_children} ->
            {:error, :max_workers_reached}

          {:error, {:already_started, _pid}} ->
            {:error, :already_started}

          {:error, reason} ->
            {:error, reason}
        end

      _pid ->
        {:error, :already_started}
    end
  end

  @doc """
  Cancels a subagent worker by subagent id.

  Sends the cancel signal to the worker and terminates the child process.
  Returns `:ok` if found, or `{:error, :not_found}` if no subagent with
  that id is running.
  """
  @spec cancel_subagent(binary()) :: :ok | {:error, :not_found}
  def cancel_subagent(subagent_id) when is_binary(subagent_id) do
    case find_subagent(subagent_id) do
      nil ->
        {:error, :not_found}

      pid ->
        # Send cancel to allow graceful cleanup
        Tet.Runtime.Subagent.Worker.cancel(pid)
        DynamicSupervisor.terminate_child(@name, pid)
    end
  end

  @doc """
  Cancels all subagents for a given parent task id.

  Returns `:ok` — cancellation is best-effort and idempotent.
  """
  @spec cancel_by_task(binary()) :: :ok
  def cancel_by_task(parent_task_id) when is_binary(parent_task_id) do
    @name
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn
      {_, pid, _, _} when is_pid(pid) ->
        case Tet.Runtime.Subagent.Worker.get_spec(pid) do
          %Tet.Subagent.Spec{parent_task_id: ^parent_task_id} ->
            Tet.Runtime.Subagent.Worker.cancel(pid)
            DynamicSupervisor.terminate_child(@name, pid)

          _ ->
            :ok
        end

      _ ->
        :ok
    end)

    :ok
  end

  @doc """
  Lists all running subagents.

  Returns a list of maps with `:id`, `:pid`, and `:spec`.
  """
  @spec list_subagents() :: [%{id: binary(), pid: pid(), spec: Tet.Subagent.Spec.t()}]
  def list_subagents do
    @name
    |> DynamicSupervisor.which_children()
    |> Enum.reduce([], fn
      {_, pid, _, _}, acc when is_pid(pid) ->
        case Tet.Runtime.Subagent.Worker.get_spec(pid) do
          %Tet.Subagent.Spec{} = spec ->
            [%{id: Tet.Subagent.Spec.subagent_id(spec), pid: pid, spec: spec} | acc]

          nil ->
            acc
        end

      _, acc ->
        acc
    end)
    |> Enum.reverse()
  end

  @doc """
  Lists subagents filtered by parent task id.

  Returns a list of subagent info maps.
  """
  @spec list_subagents(binary()) :: [%{id: binary(), pid: pid(), spec: Tet.Subagent.Spec.t()}]
  def list_subagents(parent_task_id) when is_binary(parent_task_id) do
    list_subagents()
    |> Enum.filter(fn %{spec: spec} -> spec.parent_task_id == parent_task_id end)
  end

  @doc """
  Returns the number of currently active subagent workers.
  """
  @spec count_subagents() :: non_neg_integer()
  def count_subagents do
    @name
    |> DynamicSupervisor.which_children()
    |> Enum.count(fn
      {_, pid, _, _} when is_pid(pid) -> true
      _ -> false
    end)
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp find_subagent(subagent_id) do
    @name
    |> DynamicSupervisor.which_children()
    |> Enum.find_value(nil, fn
      {_, pid, _, _} when is_pid(pid) ->
        case Tet.Runtime.Subagent.Worker.get_spec(pid) do
          %Tet.Subagent.Spec{} = spec ->
            if Tet.Subagent.Spec.subagent_id(spec) == subagent_id, do: pid

          nil ->
            nil
        end

      _ ->
        nil
    end)
  end
end
