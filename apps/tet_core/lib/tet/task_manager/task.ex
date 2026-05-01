defmodule Tet.TaskManager.Task do
  @moduledoc """
  Pure task data struct with state-machine transitions — BD-0023.

  A task is an atomically-identified unit of work belonging to one of five
  categories (`researching`, `planning`, `acting`, `verifying`, `debugging`)
  and progressing through a deterministic lifecycle:

      pending → in_progress → completed
                            ↘ failed
                            ↘ cancelled
      pending → cancelled

  Terminal states (`completed`, `failed`, `cancelled`) are immutable: no
  further transitions are valid once a task reaches one.

  This module is pure data and pure functions. It does not dispatch tools,
  touch the filesystem, shell out, persist events, or ask a terminal question.
  Runtime orchestration lives in `tet_runtime`; this module is the map, not
  the tiny robot driving the car.
  """

  alias Tet.PlanMode.Policy

  @categories Policy.all_categories()
  @statuses [:pending, :in_progress, :completed, :failed, :cancelled]
  @terminal_statuses [:completed, :failed, :cancelled]

  # Legal transitions: {from, to}
  @transitions [
    {:pending, :in_progress},
    {:pending, :cancelled},
    {:in_progress, :completed},
    {:in_progress, :failed},
    {:in_progress, :cancelled}
  ]

  @enforce_keys [:id, :title, :category]
  defstruct [
    :id,
    :title,
    :category,
    :parent_id,
    status: :pending,
    dependencies: [],
    metadata: %{}
  ]

  @type category :: Policy.category()
  @type status :: :pending | :in_progress | :completed | :failed | :cancelled
  @type t :: %__MODULE__{
          id: binary(),
          title: binary(),
          category: category(),
          parent_id: binary() | nil,
          status: status(),
          dependencies: [binary()],
          metadata: map()
        }

  @doc "Returns all valid task categories."
  @spec categories() :: [category()]
  def categories, do: @categories

  @doc "Returns all valid task statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Returns terminal task statuses (no further transitions allowed)."
  @spec terminal_statuses() :: [status()]
  def terminal_statuses, do: @terminal_statuses

  @doc "Returns the legal transition table as `[{from, to}]` pairs."
  @spec transitions() :: [{status(), status()}]
  def transitions, do: @transitions

  @doc "True when the status is terminal (no further transitions)."
  @spec terminal?(status()) :: boolean()
  def terminal?(status) when status in @terminal_statuses, do: true
  def terminal?(_status), do: false

  @doc "True when the category is plan-safe (researching or planning)."
  @spec plan_safe_category?(category()) :: boolean()
  def plan_safe_category?(category), do: Policy.plan_safe_category?(Policy.default(), category)

  @doc "True when the category is an acting category (acting, verifying, debugging)."
  @spec acting_category?(category()) :: boolean()
  def acting_category?(category), do: Policy.acting_category?(Policy.default(), category)

  @doc """
  Builds a validated task from atom or string keyed attributes.

  Required: `:id`, `:title`, `:category`.
  Optional: `:parent_id`, `:status` (default `:pending`), `:dependencies` (default `[]`),
  `:metadata` (default `%{}`).
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- fetch_binary(attrs, :id),
         {:ok, title} <- fetch_binary(attrs, :title),
         {:ok, category} <- fetch_category(attrs, :category),
         {:ok, parent_id} <- fetch_optional_binary(attrs, :parent_id),
         {:ok, status} <- fetch_status(attrs, :status, :pending),
         {:ok, dependencies} <- fetch_dependency_list(attrs, :dependencies, []),
         {:ok, metadata} <- fetch_map(attrs, :metadata, %{}),
         :ok <- validate_not_self_referencing(id, parent_id),
         :ok <- validate_not_self_dependent(id, dependencies) do
      {:ok,
       %__MODULE__{
         id: id,
         title: title,
         category: category,
         parent_id: parent_id,
         status: status,
         dependencies: dependencies,
         metadata: metadata
       }}
    end
  end

  @doc "Builds a task or raises."
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    case new(attrs) do
      {:ok, task} -> task
      {:error, reason} -> raise ArgumentError, "invalid task: #{inspect(reason)}"
    end
  end

  @doc """
  Transitions a task to a new status.

  Returns `{:ok, task}` when the transition is legal, or
  `{:error, {:invalid_task_transition, from, to}}` when it is not.
  Terminal tasks reject all transitions.
  """
  @spec transition(t(), status()) :: {:ok, t()} | {:error, term()}
  def transition(%__MODULE__{status: from} = task, to) when to in @statuses do
    if {from, to} in @transitions do
      {:ok, %__MODULE__{task | status: to}}
    else
      {:error, {:invalid_task_transition, from, to}}
    end
  end

  def transition(%__MODULE__{status: from}, to) do
    {:error, {:invalid_task_transition, from, to}}
  end

  @doc "Starts a pending task (pending → in_progress)."
  @spec start(t()) :: {:ok, t()} | {:error, term()}
  def start(%__MODULE__{} = task), do: transition(task, :in_progress)

  @doc "Completes an in-progress task (in_progress → completed)."
  @spec complete(t()) :: {:ok, t()} | {:error, term()}
  def complete(%__MODULE__{} = task), do: transition(task, :completed)

  @doc "Fails an in-progress task (in_progress → failed)."
  @spec fail(t()) :: {:ok, t()} | {:error, term()}
  def fail(%__MODULE__{} = task), do: transition(task, :failed)

  @doc "Cancels a pending or in-progress task."
  @spec cancel(t()) :: {:ok, t()} | {:error, term()}
  def cancel(%__MODULE__{} = task), do: transition(task, :cancelled)

  @doc """
  Recategorizes a task.

  Returns `{:ok, task}` with the updated category, or
  `{:error, {:invalid_task_category, category}}` when the category is unknown.
  Terminal tasks reject recategorization.
  """
  @spec recategorize(t(), category()) :: {:ok, t()} | {:error, term()}
  def recategorize(%__MODULE__{status: status}, _category)
      when status in @terminal_statuses do
    {:error, {:terminal_task_recategorize, status}}
  end

  def recategorize(%__MODULE__{} = task, category) when category in @categories do
    {:ok, %__MODULE__{task | category: category}}
  end

  def recategorize(%__MODULE__{}, category) do
    {:error, {:invalid_task_category, category}}
  end

  @doc "Adds a dependency to a non-terminal task."
  @spec add_dependency(t(), binary()) :: {:ok, t()} | {:error, term()}
  def add_dependency(%__MODULE__{status: status}, _dep_id) when status in @terminal_statuses do
    {:error, {:terminal_task_mutation, status}}
  end

  def add_dependency(%__MODULE__{id: id} = task, dep_id) when is_binary(dep_id) do
    if dep_id == id do
      {:error, {:self_dependency, id}}
    else
      if dep_id in task.dependencies do
        {:ok, task}
      else
        {:ok, %__MODULE__{task | dependencies: task.dependencies ++ [dep_id]}}
      end
    end
  end

  def add_dependency(_task, _dep_id), do: {:error, {:invalid_dependency_id, nil}}

  @doc "Removes a dependency from a non-terminal task."
  @spec remove_dependency(t(), binary()) :: {:ok, t()} | {:error, term()}
  def remove_dependency(%__MODULE__{status: status}, _dep_id) when status in @terminal_statuses do
    {:error, {:terminal_task_mutation, status}}
  end

  def remove_dependency(%__MODULE__{} = task, dep_id) when is_binary(dep_id) do
    {:ok, %__MODULE__{task | dependencies: List.delete(task.dependencies, dep_id)}}
  end

  @doc "Converts a task to a JSON-friendly map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = task) do
    %{
      id: task.id,
      title: task.title,
      category: Atom.to_string(task.category),
      parent_id: task.parent_id,
      status: Atom.to_string(task.status),
      dependencies: task.dependencies,
      metadata: task.metadata
    }
  end

  @doc "Converts a decoded map back to a validated task."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  # -- Validators --

  defp fetch_binary(attrs, key) do
    case fetch_value(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_task_field, key}}
    end
  end

  defp fetch_optional_binary(attrs, key) do
    case fetch_value(attrs, key) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_task_field, key}}
    end
  end

  defp fetch_category(attrs, key) do
    case fetch_value(attrs, key) do
      category when category in @categories -> {:ok, category}
      category when is_binary(category) -> parse_category(category)
      _ -> {:error, {:invalid_task_field, key}}
    end
  end

  defp parse_category(str) when is_binary(str) do
    case Enum.find(@categories, &(Atom.to_string(&1) == str)) do
      nil -> {:error, {:invalid_task_field, :category}}
      atom -> {:ok, atom}
    end
  end

  defp fetch_status(attrs, key, default) do
    case fetch_value(attrs, key, default) do
      status when status in @statuses -> {:ok, status}
      status when is_binary(status) -> parse_status(status)
      _ -> {:error, {:invalid_task_field, key}}
    end
  end

  defp parse_status(str) when is_binary(str) do
    case Enum.find(@statuses, &(Atom.to_string(&1) == str)) do
      nil -> {:error, {:invalid_task_field, :status}}
      atom -> {:ok, atom}
    end
  end

  defp fetch_dependency_list(attrs, key, default) do
    case fetch_value(attrs, key, default) do
      list when is_list(list) ->
        if Enum.all?(list, &valid_dep_id?/1) do
          {:ok, list}
        else
          {:error, {:invalid_task_field, key}}
        end

      _ ->
        {:error, {:invalid_task_field, key}}
    end
  end

  defp valid_dep_id?(id) when is_binary(id) and byte_size(id) > 0, do: true
  defp valid_dep_id?(_), do: false

  defp fetch_map(attrs, key, default) do
    case fetch_value(attrs, key, default) do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, {:invalid_task_field, key}}
    end
  end

  defp validate_not_self_referencing(id, parent_id) when id == parent_id,
    do: {:error, {:self_referencing_parent, id}}

  defp validate_not_self_referencing(_id, _parent_id), do: :ok

  defp validate_not_self_dependent(id, deps) do
    if id in deps do
      {:error, {:self_dependency, id}}
    else
      :ok
    end
  end

  defp fetch_value(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end
end
