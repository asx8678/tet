defmodule Tet.Mcp.CallPolicy do
  @moduledoc """
  MCP call policy as pure data.

  Defines which risk categories are allowed, which require explicit approval,
  and which are blocked outright. Inspired by Codex `exec_policy.rs` where
  policy rules classify commands into Allow/Prompt/Forbidden decisions.

  ## Invariants

  1. `blocked_categories` takes precedence over all.
  2. `require_approval` takes precedence over `allowed_categories`.
  3. A category cannot appear in both `allowed_categories` and `blocked_categories`.
  4. A category cannot appear in both `allowed_categories` and `require_approval`.
  5. Unknown categories fail-closed: if not explicitly allowed, they need approval.

  ## Relationship to other modules

  - `Tet.Mcp.Classification`: provides `category` and `risk_level` consumed here.
  - `Tet.Mcp.PermissionGate`: consumes this policy to make allow/deny/approval decisions.
  """

  alias Tet.Mcp.Classification

  @type category :: Classification.category()

  @type t :: %__MODULE__{
          allowed_categories: [category()],
          require_approval: [category()],
          blocked_categories: [category()]
        }

  @enforce_keys [:allowed_categories, :require_approval, :blocked_categories]
  defstruct [:allowed_categories, :require_approval, :blocked_categories]

  @doc """
  Builds a validated call policy from attributes, with sensible defaults.

  ## Defaults

    - `allowed_categories`: `[:read]`
    - `require_approval`: `[:write, :shell, :network, :admin]`
    - `blocked_categories`: `[]`

  ## Examples

      iex> {:ok, policy} = Tet.Mcp.CallPolicy.new(%{})
      iex> policy.allowed_categories
      [:read]

      iex> {:ok, policy} = Tet.Mcp.CallPolicy.new(%{allowed_categories: [:read, :write]})
      iex> policy.allowed_categories
      [:read, :write]
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    allowed = Map.get(attrs, :allowed_categories, [:read])
    approval = Map.get(attrs, :require_approval, [:write, :shell, :network, :admin])
    blocked = Map.get(attrs, :blocked_categories, [])

    with :ok <- validate_category_list(allowed, :allowed_categories),
         :ok <- validate_category_list(approval, :require_approval),
         :ok <- validate_category_list(blocked, :blocked_categories),
         :ok <- validate_no_overlap(allowed, blocked),
         :ok <- validate_no_overlap(allowed, approval, :allowed_require_approval_overlap) do
      {:ok,
       %__MODULE__{
         allowed_categories: allowed,
         require_approval: approval,
         blocked_categories: blocked
       }}
    end
  end

  def new(_), do: {:error, :invalid_call_policy}

  @doc "Builds a call policy or raises."
  @spec new!(map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, policy} -> policy
      {:error, reason} -> raise ArgumentError, "invalid call policy: #{inspect(reason)}"
    end
  end

  @doc "Returns the default permissive policy (read-only, everything else needs approval)."
  @spec default() :: t()
  def default, do: new!(%{})

  @doc """
  Evaluates an MCP call against this policy.

  Returns `{:ok, decision}` where decision is one of:
    - `:allow` — the call is permitted.
    - `:deny` — the call is blocked.
    - `{:needs_approval, reason}` — the call requires explicit approval.

  ## Decision flow

  1. Blocked categories take absolute precedence → `:deny`.
  2. Require-approval categories → `{:needs_approval, :policy_requires_approval}`.
  3. Allowed categories → `:allow`.
  4. Anything else → `{:needs_approval, :category_not_allowed}` (fail-closed).

  ## Examples

      iex> policy = Tet.Mcp.CallPolicy.default()
      iex> Tet.Mcp.CallPolicy.evaluate(:read, policy)
      {:ok, :allow}

      iex> policy = Tet.Mcp.CallPolicy.default()
      iex> Tet.Mcp.CallPolicy.evaluate(:shell, policy)
      {:ok, {:needs_approval, :policy_requires_approval}}
  """
  @spec evaluate(category(), t()) ::
          {:ok, :allow | :deny | {:needs_approval, atom()}} | {:error, term()}
  def evaluate(category, %__MODULE__{} = policy) when is_atom(category) do
    decision =
      cond do
        category in policy.blocked_categories ->
          :deny

        category in policy.require_approval ->
          {:needs_approval, :policy_requires_approval}

        category in policy.allowed_categories ->
          :allow

        true ->
          # Fail-closed: unknown or unlisted categories need approval
          {:needs_approval, :category_not_allowed}
      end

    {:ok, decision}
  end

  @doc """
  Returns sensible defaults per task type.

  Task types mirror `Tet.PlanMode.Policy` categories but are tuned for
  MCP-specific risk. Research/planning tasks only get read access;
  acting tasks get write; no task type gets shell by default.

  ## Examples

      iex> Tet.Mcp.CallPolicy.task_defaults()[:researching].allowed_categories
      [:read]

      iex> Tet.Mcp.CallPolicy.task_defaults()[:acting].allowed_categories
      [:read, :write]
  """
  @spec task_defaults() :: %{atom() => t()}
  def task_defaults do
    %{
      researching:
        new!(%{
          allowed_categories: [:read],
          require_approval: [:write, :network],
          blocked_categories: [:shell, :admin]
        }),
      planning:
        new!(%{
          allowed_categories: [:read],
          require_approval: [:write, :network],
          blocked_categories: [:shell, :admin]
        }),
      acting:
        new!(%{
          allowed_categories: [:read, :write],
          require_approval: [:shell, :network, :admin],
          blocked_categories: []
        }),
      verifying:
        new!(%{
          allowed_categories: [:read],
          require_approval: [:write, :network],
          blocked_categories: [:shell, :admin]
        }),
      debugging:
        new!(%{
          allowed_categories: [:read, :write],
          require_approval: [:shell, :network, :admin],
          blocked_categories: []
        }),
      documenting:
        new!(%{
          allowed_categories: [:read, :write],
          require_approval: [:network],
          blocked_categories: [:shell, :admin]
        })
    }
  end

  # -- Validators --

  defp validate_category_list(list, field) when is_list(list) do
    if Enum.all?(list, &(&1 in Classification.categories())) do
      :ok
    else
      {:error, {:invalid_categories, field}}
    end
  end

  defp validate_category_list(_, field), do: {:error, {:invalid_categories, field}}

  defp validate_no_overlap(list_a, list_b, error_tag \\ :policy_category_overlap) do
    overlap = MapSet.intersection(MapSet.new(list_a), MapSet.new(list_b))

    if MapSet.size(overlap) == 0 do
      :ok
    else
      {:error, {error_tag, MapSet.to_list(overlap)}}
    end
  end
end
