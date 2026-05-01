defmodule Tet.Subagent.Spec do
  @moduledoc """
  Subagent specification — pure data describing what a subagent is and how it runs.

  A spec declares the profile, model, tool constraints, budget, timeout, and
  parent-task correlation for a single subagent execution. Specs are validated
  on construction — callers that pass invalid attrs get `{:error, reason}`,
  never a half-baked struct.

  ## Fields

    * `profile_id` — required, the LLM profile to use (e.g. `"coder"`, `"architect"`).
    * `parent_task_id` — required, the task that spawned this subagent (correlation).
    * `model` — optional model override (e.g. `"gpt-4o"`).
    * `tool_allowlist` — optional list of allowed tool names; nil means no restriction.
    * `budget` — optional max cost budget in milli-units (e.g. 500_000 = $0.005).
    * `timeout` — optional max execution time in milliseconds.
  """

  alias Tet.Entity

  @enforce_keys [:profile_id, :parent_task_id]
  defstruct [:profile_id, :parent_task_id, :model, :tool_allowlist, :budget, :timeout]

  @type t :: %__MODULE__{
          profile_id: String.t(),
          parent_task_id: String.t(),
          model: String.t() | nil,
          tool_allowlist: [String.t()] | nil,
          budget: pos_integer() | nil,
          timeout: pos_integer() | nil
        }

  @doc """
  Builds a validated subagent spec from atom- or string-keyed attrs.

  ## Required attrs

    * `:profile_id` — binary string
    * `:parent_task_id` — binary string

  ## Optional attrs

    * `:model` — binary string
    * `:tool_allowlist` — list of binary strings
    * `:budget` — positive integer
    * `:timeout` — positive integer

  Returns `{:ok, %Tet.Subagent.Spec{}}` or `{:error, reason}`.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, profile_id} <- Entity.fetch_required_binary(attrs, :profile_id, :subagent_spec),
         {:ok, parent_task_id} <-
           Entity.fetch_required_binary(attrs, :parent_task_id, :subagent_spec),
         {:ok, model} <- Entity.fetch_optional_binary(attrs, :model, :subagent_spec),
         {:ok, tool_allowlist} <- Entity.fetch_string_list(attrs, :tool_allowlist, :subagent_spec),
         {:ok, budget} <- Entity.fetch_optional_positive_integer(attrs, :budget, :subagent_spec),
         {:ok, timeout} <- Entity.fetch_optional_positive_integer(attrs, :timeout, :subagent_spec) do
      tool_allowlist = if tool_allowlist == [], do: nil, else: tool_allowlist

      {:ok,
       %__MODULE__{
         profile_id: profile_id,
         parent_task_id: parent_task_id,
         model: model,
         tool_allowlist: tool_allowlist,
         budget: budget,
         timeout: timeout
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_subagent_spec}

  @doc """
  Builds a subagent spec or raises `ArgumentError`.
  """
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    case new(attrs) do
      {:ok, spec} -> spec
      {:error, reason} -> raise ArgumentError, "invalid subagent spec: #{inspect(reason)}"
    end
  end

  @doc """
  Converts a spec to a JSON-friendly map with string keys.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = spec) do
    %{
      profile_id: spec.profile_id,
      parent_task_id: spec.parent_task_id,
      model: spec.model,
      tool_allowlist: spec.tool_allowlist,
      budget: spec.budget,
      timeout: spec.timeout
    }
  end

  @doc """
  Converts a decoded map back to a validated spec.

  Strips nil-valued keys before validation so that fields like
  `tool_allowlist` and `budget` round-trip cleanly through
  `to_map/1` → `from_map/1`.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs) do
    attrs
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
    |> new()
  end

  @doc """
  Returns the subagent id to use for a subagent started with this spec.

  The id is deterministic for a given parent task (single subagent per task
  in v1), but could be extended to support multiple subagents by passing a
  suffix or generating a random component.
  """
  @spec subagent_id(t()) :: String.t()
  def subagent_id(%__MODULE__{} = spec) do
    "sub_#{spec.parent_task_id}"
  end
end
