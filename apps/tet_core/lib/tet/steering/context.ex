defmodule Tet.Steering.Context do
  @moduledoc """
  Steering relevance context — BD-0031.

  Describes the inputs that inform a steering decision: recent events, the
  active task, task progress, tool usage summary, and session age.

  This struct is populated by the runtime before invoking a steering evaluator.
  It is pure data: no side effects, no filesystem, no GenServer calls.

  ## Relationship to other modules

    - `Tet.Steering.Decision` (BD-0031): the context is consumed by the
      evaluator to produce a decision. The decision records this context
      in its `context` field for auditability.
    - `Tet.Event` (BD-0022): `recent_events` references event structs.
    - `Tet.TaskManager.Task` (BD-0023): `active_task` and `task_progress`
      reference task data.
  """

  @enforce_keys [:session_age]
  defstruct [
    :session_age,
    recent_events: [],
    active_task: nil,
    task_progress: %{},
    tool_usage_summary: %{}
  ]

  @type t :: %__MODULE__{
          recent_events: [map()],
          active_task: map() | nil,
          task_progress: map(),
          tool_usage_summary: map(),
          session_age: non_neg_integer()
        }

  @doc """
  Builds a validated steering context from attributes.

  Required: `:session_age` (non-negative integer).
  Optional: `:recent_events` (list, default []), `:active_task` (map or nil,
  default nil), `:task_progress` (map, default %{}),
  `:tool_usage_summary` (map, default %{}).
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, session_age} <- fetch_session_age(attrs),
         {:ok, recent_events} <- fetch_list(attrs, :recent_events, []),
         {:ok, active_task} <- fetch_optional_map(attrs, :active_task),
         {:ok, task_progress} <- fetch_map(attrs, :task_progress, %{}),
         {:ok, tool_usage_summary} <- fetch_map(attrs, :tool_usage_summary, %{}) do
      {:ok,
       %__MODULE__{
         session_age: session_age,
         recent_events: recent_events,
         active_task: active_task,
         task_progress: task_progress,
         tool_usage_summary: tool_usage_summary
       }}
    end
  end

  @doc "Builds a steering context or raises."
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    case new(attrs) do
      {:ok, ctx} -> ctx
      {:error, reason} -> raise ArgumentError, "invalid steering context: #{inspect(reason)}"
    end
  end

  @doc """
  Converts a context to a JSON-friendly map.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = ctx) do
    %{
      recent_events: ctx.recent_events,
      active_task: ctx.active_task,
      task_progress: ctx.task_progress,
      tool_usage_summary: ctx.tool_usage_summary,
      session_age: ctx.session_age
    }
  end

  @doc """
  Converts a decoded map back to a validated context.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  # ── Validators ──────────────────────────────────────────────────────

  defp fetch_session_age(attrs) do
    case fetch_value(attrs, :session_age) do
      age when is_integer(age) and age >= 0 -> {:ok, age}
      age when is_number(age) and age >= 0 -> {:ok, trunc(age)}
      _ -> {:error, {:invalid_context_field, :session_age}}
    end
  end

  defp fetch_list(attrs, key, default) do
    case fetch_value(attrs, key, default) do
      value when is_list(value) -> {:ok, value}
      _ -> {:error, {:invalid_context_field, key}}
    end
  end

  defp fetch_map(attrs, key, default) do
    case fetch_value(attrs, key, default) do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, {:invalid_context_field, key}}
    end
  end

  defp fetch_optional_map(attrs, key) do
    case fetch_value(attrs, key) do
      nil -> {:ok, nil}
      value when is_map(value) -> {:ok, value}
      _ -> {:error, {:invalid_context_field, key}}
    end
  end

  defp fetch_value(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end
end
