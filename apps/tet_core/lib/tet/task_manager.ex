defmodule Tet.TaskManager do
  @moduledoc """
  TaskManager facade — BD-0023.

  Composes `Task`, `State`, and `Guidance` into a single public API surface
  for the rest of the umbrella. Like `Tet.PlanMode`, this facade keeps
  implementation details internal while exposing a clean boundary.

  ## What this module does

  - Provides task lifecycle state-machine transitions.
  - Manages active-task selection and dependency tracking.
  - Generates category-based guidance events.
  - Keeps everything pure and side-effect-free: no filesystem, no shell,
    no GenServer.

  ## What this module does NOT do

  - Dispatch tool execution (that's runtime).
  - Persist events (that's store).
  - Run hooks (future BD-0024 concern).
  - Own process supervision (that's runtime).

  ## Relationship to other modules

  - `Tet.TaskManager.Task`: individual task struct and transitions.
  - `Tet.TaskManager.State`: task collection, active-task selection, deps.
  - `Tet.TaskManager.Guidance`: category-based guidance generation.
  - `Tet.PlanMode.Policy` (BD-0025): category definitions consumed by tasks.
  - `Tet.PlanMode.Gate` (BD-0025): uses `task_id` and `task_category` from
    the active task to make gate decisions.
  - `Tet.Runtime.State` (BD-0016): `active_task_refs` field references task IDs
    managed by this module.
  """

  alias Tet.TaskManager.{Guidance, State, Task}

  # ── Delegated task operations ────────────────────────────────────

  @doc "Creates a validated task struct."
  defdelegate new_task(attrs), to: Task, as: :new

  @doc "Creates a task struct or raises."
  defdelegate new_task!(attrs), to: Task, as: :new!

  @doc "Returns all valid task categories."
  defdelegate categories, to: Task

  @doc "Returns all valid task statuses."
  defdelegate statuses, to: Task

  @doc "Returns the legal transition table."
  defdelegate transitions, to: Task

  # ── Delegated state operations ───────────────────────────────────

  @doc "Creates a validated TaskManager state."
  defdelegate new_state(attrs), to: State, as: :new

  @doc "Creates a TaskManager state or raises."
  defdelegate new_state!(attrs), to: State, as: :new!

  @doc "Adds a task to the registry."
  defdelegate add_task(state, task), to: State

  @doc "Gets a task by ID."
  defdelegate get_task(state, id), to: State

  @doc "Lists all tasks."
  defdelegate list_tasks(state), to: State

  @doc "Transitions a task's status."
  defdelegate transition(state, task_id, new_status), to: State

  @doc "Starts a pending task."
  defdelegate start_task(state, task_id), to: State

  @doc "Completes an in-progress task."
  defdelegate complete_task(state, task_id), to: State

  @doc "Fails an in-progress task."
  defdelegate fail_task(state, task_id), to: State

  @doc "Cancels a pending or in-progress task."
  defdelegate cancel_task(state, task_id), to: State

  @doc "Recategorizes a task."
  defdelegate recategorize(state, task_id, category), to: State

  @doc "Sets the active task."
  defdelegate set_active(state, task_id), to: State

  @doc "Clears the active task reference."
  defdelegate clear_active(state), to: State

  @doc "Returns the active task."
  defdelegate active_task(state), to: State

  @doc "Returns the active task category."
  defdelegate active_category(state), to: State

  @doc "Auto-selects the next eligible task as active."
  defdelegate select_next(state), to: State

  @doc "Returns guidance for the active task."
  defdelegate guidance(state), to: State

  @doc "Returns guidance for a specific category."
  defdelegate guidance_for_category(category), to: Guidance, as: :for_category

  @doc "Checks if a task's dependencies are satisfied."
  defdelegate dependencies_satisfied?(state, task_id), to: State

  @doc "Checks if a task can be started."
  defdelegate can_start?(state, task_id), to: State

  # ── Convenience ──────────────────────────────────────────────────

  @doc """
  Starts a task and immediately sets it as active.

  Convenience for the common pattern of start → activate.
  """
  @spec start_and_activate(State.t(), binary()) :: {:ok, State.t()} | {:error, term()}
  def start_and_activate(%State{} = state, task_id) when is_binary(task_id) do
    with {:ok, state} <- State.start_task(state, task_id),
         {:ok, state} <- State.set_active(state, task_id) do
      {:ok, state}
    end
  end

  @doc """
  Completes the active task and auto-selects the next eligible one.

  Convenience for the common pattern of complete → select_next.
  """
  @spec complete_and_advance(State.t()) :: {:ok, State.t()} | {:error, term()}
  def complete_and_advance(%State{active_task_id: nil} = state), do: {:ok, state}

  def complete_and_advance(%State{active_task_id: task_id} = state) when is_binary(task_id) do
    with {:ok, state} <- State.complete_task(state, task_id) do
      State.select_next(state)
    end
  end

  @doc "Serializes state to a JSON-friendly map."
  defdelegate to_map(state), to: State

  @doc "Deserializes a map back to validated state."
  defdelegate from_map(attrs), to: State
end
