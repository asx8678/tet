defmodule Tet.TaskManager.State do
  @moduledoc """
  TaskManager collection state — pure data + state machine — BD-0023.

  Owns the task registry, active-task selection, dependency tracking, and
  eligibility queries. Like `Tet.Runtime.State` (BD-0016), this is the map,
  not the robot driving the car — pure functions, no side effects.

  ## Invariants

  1. The active task must be `:in_progress`.
  2. All referenced dependency IDs must exist in the task registry.
  3. No circular dependencies (the task manager does not allow adding a task
     that depends on a task which (transitively) depends on it).
  4. Terminal tasks are immutable — no status transitions, dependency changes,
     or recategorization.

  ## Relationship to other modules

  - `Tet.TaskManager.Task` (BD-0023): individual task struct and transitions.
  - `Tet.PlanMode.Policy` (BD-0025): category definitions consumed by tasks.
  - `Tet.PlanMode.Gate` (BD-0025): uses `task_id` and `task_category` from
    the active task to make gate decisions.
  - `Tet.Runtime.State` (BD-0016): `active_task_refs` field references task IDs
    managed here.
  """

  alias Tet.TaskManager.{Guidance, Task}

  @enforce_keys [:id]
  defstruct [
    :id,
    tasks: %{},
    active_task_id: nil,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: binary(),
          tasks: %{binary() => Task.t()},
          active_task_id: binary() | nil,
          metadata: map()
        }

  @doc "Builds a validated task manager state from attributes."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- fetch_binary(attrs, :id),
         {:ok, tasks_attrs} <- fetch_optional_map(attrs, :tasks, %{}),
         {:ok, tasks} <- build_task_map(tasks_attrs),
         {:ok, active_task_id} <- fetch_optional_binary(attrs, :active_task_id),
         {:ok, metadata} <- fetch_map(attrs, :metadata, %{}),
         :ok <- validate_active_task(tasks, active_task_id) do
      {:ok,
       %__MODULE__{
         id: id,
         tasks: tasks,
         active_task_id: active_task_id,
         metadata: metadata
       }}
    end
  end

  @doc "Builds state or raises."
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    case new(attrs) do
      {:ok, state} -> state
      {:error, reason} -> raise ArgumentError, "invalid task manager state: #{inspect(reason)}"
    end
  end

  # ── Task operations ──────────────────────────────────────────────

  @doc """
  Adds a task to the registry.

  Validates that the task ID is unique, all declared dependencies exist,
  and no circular dependency would result.
  """
  @spec add_task(t(), Task.t() | map()) :: {:ok, t()} | {:error, term()}
  def add_task(%__MODULE__{} = state, %Task{} = task) do
    with :ok <- validate_unique_id(state, task.id),
         :ok <- validate_dependencies_exist(state, task.dependencies),
         :ok <- validate_no_cycle(state, task.id, task.dependencies) do
      tasks = Map.put(state.tasks, task.id, task)
      {:ok, %__MODULE__{state | tasks: tasks}}
    end
  end

  def add_task(%__MODULE__{} = state, attrs) when is_map(attrs) do
    with {:ok, task} <- Task.new(attrs) do
      add_task(state, task)
    end
  end

  @doc "Returns a task by ID, or nil."
  @spec get_task(t(), binary()) :: Task.t() | nil
  def get_task(%__MODULE__{tasks: tasks}, id) when is_binary(id) do
    Map.get(tasks, id)
  end

  @doc "Returns all tasks as a list."
  @spec list_tasks(t()) :: [Task.t()]
  def list_tasks(%__MODULE__{tasks: tasks}) do
    Map.values(tasks)
  end

  @doc "Returns tasks filtered by status."
  @spec tasks_by_status(t(), Task.status()) :: [Task.t()]
  def tasks_by_status(%__MODULE__{tasks: tasks}, status) do
    Enum.filter(Map.values(tasks), &(&1.status == status))
  end

  @doc "Returns tasks filtered by category."
  @spec tasks_by_category(t(), Task.category()) :: [Task.t()]
  def tasks_by_category(%__MODULE__{tasks: tasks}, category) do
    Enum.filter(Map.values(tasks), &(&1.category == category))
  end

  # ── Transition operations ────────────────────────────────────────

  @doc """
  Transitions a task's status.

  If the transitioned task was the active task and becomes terminal,
  the active task is cleared.
  """
  @spec transition(t(), binary(), Task.status()) :: {:ok, t()} | {:error, term()}
  def transition(%__MODULE__{} = state, task_id, new_status) when is_binary(task_id) do
    with {:ok, task} <- fetch_existing_task(state, task_id),
         {:ok, updated_task} <- Task.transition(task, new_status) do
      state = put_task(state, updated_task)

      state =
        if task_id == state.active_task_id and Task.terminal?(new_status) do
          %__MODULE__{state | active_task_id: nil}
        else
          state
        end

      {:ok, state}
    end
  end

  @doc "Starts a pending task (pending → in_progress)."
  @spec start_task(t(), binary()) :: {:ok, t()} | {:error, term()}
  def start_task(%__MODULE__{} = state, task_id) when is_binary(task_id) do
    with {:ok, task} <- fetch_existing_task(state, task_id),
         :ok <- validate_dependencies_satisfied(state, task) do
      transition(state, task_id, :in_progress)
    end
  end

  @doc "Completes an in-progress task."
  @spec complete_task(t(), binary()) :: {:ok, t()} | {:error, term()}
  def complete_task(%__MODULE__{} = state, task_id) when is_binary(task_id) do
    transition(state, task_id, :completed)
  end

  @doc "Fails an in-progress task."
  @spec fail_task(t(), binary()) :: {:ok, t()} | {:error, term()}
  def fail_task(%__MODULE__{} = state, task_id) when is_binary(task_id) do
    transition(state, task_id, :failed)
  end

  @doc "Cancels a pending or in-progress task."
  @spec cancel_task(t(), binary()) :: {:ok, t()} | {:error, term()}
  def cancel_task(%__MODULE__{} = state, task_id) when is_binary(task_id) do
    transition(state, task_id, :cancelled)
  end

  # ── Recategorize ────────────────────────────────────────────────

  @doc "Recategorizes a task."
  @spec recategorize(t(), binary(), Task.category()) :: {:ok, t()} | {:error, term()}
  def recategorize(%__MODULE__{} = state, task_id, category) when is_binary(task_id) do
    with {:ok, task} <- fetch_existing_task(state, task_id),
         {:ok, updated_task} <- Task.recategorize(task, category) do
      {:ok, put_task(state, updated_task)}
    end
  end

  # ── Dependency operations ────────────────────────────────────────

  @doc "Adds a dependency to a task."
  @spec add_dependency(t(), binary(), binary()) :: {:ok, t()} | {:error, term()}
  def add_dependency(%__MODULE__{} = state, task_id, dep_id)
      when is_binary(task_id) and is_binary(dep_id) do
    with {:ok, task} <- fetch_existing_task(state, task_id),
         {:ok, _} <- fetch_existing_task(state, dep_id),
         {:ok, updated_task} <- Task.add_dependency(task, dep_id),
         :ok <- validate_no_cycle(state, task_id, updated_task.dependencies) do
      {:ok, put_task(state, updated_task)}
    end
  end

  @doc "Removes a dependency from a task."
  @spec remove_dependency(t(), binary(), binary()) :: {:ok, t()} | {:error, term()}
  def remove_dependency(%__MODULE__{} = state, task_id, dep_id)
      when is_binary(task_id) and is_binary(dep_id) do
    with {:ok, task} <- fetch_existing_task(state, task_id),
         {:ok, updated_task} <- Task.remove_dependency(task, dep_id) do
      {:ok, put_task(state, updated_task)}
    end
  end

  @doc "True when all dependencies for a task are completed."
  @spec dependencies_satisfied?(t(), binary()) :: boolean()
  def dependencies_satisfied?(%__MODULE__{tasks: tasks}, task_id) when is_binary(task_id) do
    case Map.get(tasks, task_id) do
      nil -> false
      task -> all_deps_completed?(tasks, task.dependencies)
    end
  end

  @doc "True when a specific task can be started (pending + deps met)."
  @spec can_start?(t(), binary()) :: boolean()
  def can_start?(%__MODULE__{} = state, task_id) when is_binary(task_id) do
    case Map.get(state.tasks, task_id) do
      %Task{status: :pending} -> dependencies_satisfied?(state, task_id)
      _ -> false
    end
  end

  # ── Active-task selection ────────────────────────────────────────

  @doc """
  Sets the active task.

  The task must exist and be `:in_progress`. If a different task is currently
  active, it remains in_progress (no auto-transition).
  """
  @spec set_active(t(), binary()) :: {:ok, t()} | {:error, term()}
  def set_active(%__MODULE__{} = state, task_id) when is_binary(task_id) do
    case Map.get(state.tasks, task_id) do
      %Task{status: :in_progress} ->
        {:ok, %__MODULE__{state | active_task_id: task_id}}

      %Task{status: status} ->
        {:error, {:active_task_not_in_progress, task_id, status}}

      nil ->
        {:error, {:task_not_found, task_id}}
    end
  end

  @doc "Clears the active task reference."
  @spec clear_active(t()) :: t()
  def clear_active(%__MODULE__{} = state), do: %__MODULE__{state | active_task_id: nil}

  @doc "Returns the active task, or nil."
  @spec active_task(t()) :: Task.t() | nil
  def active_task(%__MODULE__{active_task_id: nil}), do: nil

  def active_task(%__MODULE__{active_task_id: id, tasks: tasks}) do
    Map.get(tasks, id)
  end

  @doc "Returns the active task category, or nil."
  @spec active_category(t()) :: Task.category() | nil
  def active_category(%__MODULE__{} = state) do
    case active_task(state) do
      %Task{category: cat} -> cat
      nil -> nil
    end
  end

  @doc """
  Auto-selects the next eligible task as active.

  Eligibility: the task must be `:in_progress` and all its dependencies must
  be `:completed`. Among eligible tasks, the first by insertion order is
  selected. Returns `{:ok, state}` with `active_task_id` set, or
  `{:ok, state}` unchanged if no eligible task exists.
  """
  @spec select_next(t()) :: {:ok, t()}
  def select_next(%__MODULE__{} = state) do
    candidates =
      state.tasks
      |> Enum.filter(fn {_id, %Task{status: status}} -> status == :in_progress end)
      |> Enum.filter(fn {_id, %Task{} = task} ->
        all_deps_completed?(state.tasks, task.dependencies)
      end)
      |> Enum.sort_by(fn {id, _task} -> id end)

    case candidates do
      [{task_id, _task} | _] ->
        {:ok, %__MODULE__{state | active_task_id: task_id}}

      [] ->
        {:ok, %__MODULE__{state | active_task_id: nil}}
    end
  end

  # ── Guidance ──────────────────────────────────────────────────────

  @doc "Returns guidance for the active task's category."
  @spec guidance(t()) :: Guidance.guidance_result()
  def guidance(%__MODULE__{} = state) do
    Guidance.for_state(state)
  end

  @doc "Returns guidance for a specific category."
  @spec guidance_for_category(Task.category()) :: Guidance.guidance_result()
  def guidance_for_category(category) do
    Guidance.for_category(category)
  end

  # ── Serialization ────────────────────────────────────────────────

  @doc "Converts state to a JSON-friendly map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = state) do
    %{
      id: state.id,
      tasks:
        Map.new(state.tasks, fn {id, task} ->
          {id, Task.to_map(task)}
        end),
      active_task_id: state.active_task_id,
      metadata: state.metadata
    }
  end

  @doc "Converts a decoded map back to a validated state."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs) do
    with {:ok, id} <- fetch_binary(attrs, :id),
         {:ok, tasks_attrs} <- fetch_optional_map(attrs, :tasks, %{}),
         {:ok, tasks} <- build_task_map(tasks_attrs),
         {:ok, active_task_id} <- fetch_optional_binary(attrs, :active_task_id),
         {:ok, metadata} <- fetch_map(attrs, :metadata, %{}),
         :ok <- validate_active_task(tasks, active_task_id) do
      {:ok,
       %__MODULE__{
         id: id,
         tasks: tasks,
         active_task_id: active_task_id,
         metadata: metadata
       }}
    end
  end

  # ── Private helpers ──────────────────────────────────────────────

  defp put_task(%__MODULE__{} = state, %Task{} = task) do
    %__MODULE__{state | tasks: Map.put(state.tasks, task.id, task)}
  end

  defp fetch_existing_task(%__MODULE__{tasks: tasks}, task_id) do
    case Map.get(tasks, task_id) do
      nil -> {:error, {:task_not_found, task_id}}
      task -> {:ok, task}
    end
  end

  defp validate_unique_id(%__MODULE__{tasks: tasks}, task_id) do
    if Map.has_key?(tasks, task_id) do
      {:error, {:duplicate_task_id, task_id}}
    else
      :ok
    end
  end

  defp validate_dependencies_exist(%__MODULE__{tasks: tasks}, dependencies) do
    missing = Enum.reject(dependencies, &Map.has_key?(tasks, &1))

    if missing == [] do
      :ok
    else
      {:error, {:unknown_dependencies, missing}}
    end
  end

  defp validate_no_cycle(%__MODULE__{tasks: tasks}, task_id, dependencies) do
    if would_create_cycle?(tasks, task_id, dependencies) do
      {:error, {:circular_dependency, task_id}}
    else
      :ok
    end
  end

  # DFS from each dependency to see if it reaches back to task_id
  defp would_create_cycle?(tasks, task_id, dependencies) do
    Enum.any?(dependencies, fn dep_id ->
      reaches?(tasks, dep_id, task_id, MapSet.new())
    end)
  end

  defp reaches?(tasks, current, target, visited) do
    cond do
      current == target -> true
      MapSet.member?(visited, current) -> false
      true ->
        case Map.get(tasks, current) do
          nil -> false
          task ->
            visited = MapSet.put(visited, current)
            Enum.any?(task.dependencies, &reaches?(tasks, &1, target, visited))
        end
    end
  end

  defp validate_dependencies_satisfied(%__MODULE__{tasks: tasks}, %Task{} = task) do
    if all_deps_completed?(tasks, task.dependencies) do
      :ok
    else
      {:error, {:unmet_dependencies, task.id, unmet_deps(tasks, task.dependencies)}}
    end
  end

  defp all_deps_completed?(tasks, dependencies) do
    Enum.all?(dependencies, fn dep_id ->
      case Map.get(tasks, dep_id) do
        %Task{status: :completed} -> true
        _ -> false
      end
    end)
  end

  defp unmet_deps(tasks, dependencies) do
    Enum.filter(dependencies, fn dep_id ->
      case Map.get(tasks, dep_id) do
        %Task{status: :completed} -> false
        _ -> true
      end
    end)
  end

  defp validate_active_task(_tasks, nil), do: :ok

  defp validate_active_task(tasks, active_task_id) when is_binary(active_task_id) do
    case Map.get(tasks, active_task_id) do
      %Task{status: :in_progress} -> :ok
      %Task{status: status} -> {:error, {:active_task_not_in_progress, active_task_id, status}}
      nil -> {:error, {:task_not_found, active_task_id}}
    end
  end

  defp build_task_map(tasks_attrs) when is_map(tasks_attrs) do
    tasks_attrs
    |> Enum.map(fn {id, attrs} ->
      attrs = Map.put(attrs, :id, id)
      Task.new(attrs)
    end)
    |> accumulate_tasks()
  end

  defp accumulate_tasks(results) do
    Enum.reduce_while(results, {:ok, %{}}, fn
      {:ok, task}, {:ok, acc} -> {:cont, {:ok, Map.put(acc, task.id, task)}}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
    end)
  end

  defp fetch_binary(attrs, key) do
    case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key))) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_task_manager_field, key}}
    end
  end

  defp fetch_optional_binary(attrs, key) do
    case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key))) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_task_manager_field, key}}
    end
  end

  defp fetch_optional_map(attrs, key, default) do
    case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default)) do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, {:invalid_task_manager_field, key}}
    end
  end

  defp fetch_map(attrs, key, default) do
    case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default)) do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, {:invalid_task_manager_field, key}}
    end
  end
end
