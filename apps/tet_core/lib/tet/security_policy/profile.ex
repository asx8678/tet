defmodule Tet.SecurityPolicy.Profile do
  @moduledoc """
  Security policy profile struct — BD-0067.

  A `Profile` bundles every policy dimension into a single struct that can
  be evaluated atomically. Each dimension is independently configurable but
  **all dimensions are consulted** on every `check/3` call — the most
  restrictive result wins (deny always beats allow).

  ## Dimensions

    - **approval_mode** — how aggressively the system auto-approves actions.
    - **sandbox_profile** — filesystem / network sandbox constraints.
    - **deny_globs** — glob patterns that *always* block matching paths/actions.
    - **allow_paths** — glob patterns that permit matching paths (overridden by deny).
    - **mcp_trust** — maximum MCP classification category allowed without approval.
    - **remote_trust** — minimum `Tet.Remote.TrustBoundary` level for remote ops.
    - **repair_approval** — mapping of repair strategies to required approval mode.

  ## Invariants

  1. `deny_globs` always beats `allow_paths` — no exceptions.
  2. `:always_deny` approval mode short-circuits everything.
  3. Sandbox profile constraints are checked *after* approval mode but
     *before* allow/deny globs.
  4. MCP and remote trust are consulted independently — both must pass.
  5. Repair operations require the mapped approval level or higher.
  """

  alias Tet.Remote.TrustBoundary
  alias Tet.Mcp.Classification

  # --- Approval modes ---

  @approval_modes [:auto_approve, :suggest_approve, :require_approve, :always_deny]

  @doc "All valid approval modes, ordered from most to least permissive."
  @spec approval_modes() :: [
          :auto_approve | :suggest_approve | :require_approve | :always_deny
        ]
  def approval_modes, do: @approval_modes

  # --- Sandbox profiles ---

  @sandbox_profiles [:unrestricted, :workspace_only, :read_only, :no_network, :locked_down]

  @doc "All valid sandbox profiles, ordered from most to least restrictive."
  @spec sandbox_profiles() :: [
          :unrestricted | :workspace_only | :read_only | :no_network | :locked_down
        ]
  def sandbox_profiles, do: @sandbox_profiles

  @doc "Returns the restrictiveness ranking of a sandbox profile (higher = more restricted)."
  @spec sandbox_ranking(atom()) :: non_neg_integer() | nil
  def sandbox_ranking(:unrestricted), do: 0
  def sandbox_ranking(:workspace_only), do: 1
  def sandbox_ranking(:read_only), do: 2
  def sandbox_ranking(:no_network), do: 3
  def sandbox_ranking(:locked_down), do: 4
  def sandbox_ranking(_), do: nil

  @doc "Returns true when `level` is at least as restrictive as `required`."
  @spec sandbox_at_least?(atom(), atom()) :: boolean()
  def sandbox_at_least?(level, required) when level == required, do: true

  def sandbox_at_least?(level, required) do
    # Partial order: unrestricted < workspace_only < {read_only, no_network} < locked_down
    # read_only and no_network are INCOMPARABLE
    case {level, required} do
      {:unrestricted, _} -> false
      {_, :unrestricted} -> true
      {:locked_down, _} -> true
      {_, :locked_down} -> false
      {:workspace_only, _} -> false
      {_, :workspace_only} -> level in [:read_only, :no_network]
      {:read_only, :no_network} -> false
      {:no_network, :read_only} -> false
      _ -> false
    end
  end

  # --- Struct ---

  @enforce_keys [:approval_mode, :sandbox_profile]
  defstruct [
    :approval_mode,
    :sandbox_profile,
    deny_globs: [],
    allow_paths: nil,
    mcp_trust: :read,
    remote_trust: :untrusted_remote,
    repair_approval: %{},
    metadata: %{}
  ]

  @type approval_mode :: :auto_approve | :suggest_approve | :require_approve | :always_deny
  @type sandbox_profile ::
          :unrestricted | :workspace_only | :read_only | :no_network | :locked_down
  @type repair_strategy :: :retry | :fallback | :patch | :human
  @type glob :: String.t()
  @type t :: %__MODULE__{
          approval_mode: approval_mode(),
          sandbox_profile: sandbox_profile(),
          deny_globs: [glob()],
          allow_paths: [glob()] | nil,
          mcp_trust: Classification.category(),
          remote_trust: TrustBoundary.trust_level(),
          repair_approval: %{repair_strategy() => approval_mode()},
          metadata: map()
        }

  @doc """
  Builds a validated security policy profile.

  ## Defaults

    - `approval_mode`: `:require_approve`
    - `sandbox_profile`: `:workspace_only`
    - `deny_globs`: `[]`
    - `allow_paths`: `nil` (no restriction; `[]` means allow nothing)
    - `mcp_trust`: `:read`
    - `remote_trust`: `:untrusted_remote`
    - `repair_approval`: `%{retry: :auto_approve, fallback: :suggest_approve, patch: :require_approve, human: :always_deny}`

  ## Examples

      iex> {:ok, profile} = Tet.SecurityPolicy.Profile.new(%{})
      iex> profile.approval_mode
      :require_approve

      iex> {:ok, profile} = Tet.SecurityPolicy.Profile.new(%{approval_mode: :auto_approve, sandbox_profile: :unrestricted})
      iex> profile.approval_mode
      :auto_approve
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    approval_mode = Map.get(attrs, :approval_mode, :require_approve)
    sandbox = Map.get(attrs, :sandbox_profile, :workspace_only)
    deny_globs = Map.get(attrs, :deny_globs, [])
    allow_paths = Map.get(attrs, :allow_paths, nil)
    mcp_trust = Map.get(attrs, :mcp_trust, :read)
    remote_trust = Map.get(attrs, :remote_trust, :untrusted_remote)
    repair_approval = Map.get(attrs, :repair_approval, default_repair_approval())
    metadata = Map.get(attrs, :metadata, %{})

    with :ok <- validate_approval_mode(approval_mode),
         :ok <- validate_sandbox_profile(sandbox),
         :ok <- validate_glob_list(deny_globs, :deny_globs),
         :ok <- validate_glob_list(allow_paths, :allow_paths),
         :ok <- validate_mcp_trust(mcp_trust),
         :ok <- validate_remote_trust(remote_trust),
         :ok <- validate_repair_approval(repair_approval),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         approval_mode: approval_mode,
         sandbox_profile: sandbox,
         deny_globs: deny_globs,
         allow_paths: allow_paths,
         mcp_trust: mcp_trust,
         remote_trust: remote_trust,
         repair_approval: repair_approval,
         metadata: metadata
       }}
    end
  end

  def new(_), do: {:error, :invalid_profile}

  @doc "Builds a profile or raises."
  @spec new!(map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, profile} -> profile
      {:error, reason} -> raise ArgumentError, "invalid security profile: #{inspect(reason)}"
    end
  end

  @doc "Returns the default profile (conservative)."
  @spec default() :: t()
  def default, do: new!(%{})

  @doc "Returns a fully permissive profile (auto-approve, unrestricted sandbox)."
  @spec permissive() :: t()
  def permissive do
    new!(%{
      approval_mode: :auto_approve,
      sandbox_profile: :unrestricted,
      mcp_trust: :admin,
      remote_trust: :local,
      deny_globs: [],
      allow_paths: ["**"]
    })
  end

  @doc "Returns a fully locked-down profile."
  @spec locked_down() :: t()
  def locked_down do
    new!(%{
      approval_mode: :always_deny,
      sandbox_profile: :locked_down,
      mcp_trust: :read,
      remote_trust: :untrusted_remote,
      deny_globs: ["**"],
      allow_paths: [],
      repair_approval: %{
        retry: :always_deny,
        fallback: :always_deny,
        patch: :always_deny,
        human: :always_deny
      }
    })
  end

  @doc "Returns the approval mode ranking (higher = more permissive)."
  @spec approval_ranking(approval_mode()) :: non_neg_integer()
  def approval_ranking(:auto_approve), do: 3
  def approval_ranking(:suggest_approve), do: 2
  def approval_ranking(:require_approve), do: 1
  def approval_ranking(:always_deny), do: 0

  @doc "Returns true when `mode` is at least as permissive as `required`."
  @spec approval_at_least?(approval_mode(), approval_mode()) :: boolean()
  def approval_at_least?(mode, required) do
    approval_ranking(mode) >= approval_ranking(required)
  end

  @doc "Returns the default repair approval mapping."
  @spec default_repair_approval() :: %{repair_strategy() => approval_mode()}
  def default_repair_approval do
    %{
      retry: :auto_approve,
      fallback: :suggest_approve,
      patch: :require_approve,
      human: :always_deny
    }
  end

  @doc "Converts a profile to a JSON-friendly map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = profile) do
    %{
      approval_mode: profile.approval_mode,
      sandbox_profile: profile.sandbox_profile,
      deny_globs: profile.deny_globs,
      allow_paths: profile.allow_paths,
      mcp_trust: profile.mcp_trust,
      remote_trust: profile.remote_trust,
      repair_approval: profile.repair_approval,
      metadata: profile.metadata
    }
  end

  @doc """
  Merges two profiles, choosing the MORE RESTRICTIVE value for security dimensions.

  Security dimensions use restrictive merge (safer result wins):

    - `approval_mode` — picks the more restrictive (lower ranking)
    - `sandbox_profile` — picks the more restrictive (higher ranking)
    - `mcp_trust` — picks the lower trust (lower risk_index)
    - `remote_trust` — picks the higher trust requirement (higher ranking)

  Aggregation dimensions use restrictive merge:

    - `deny_globs` — union of both
    - `allow_paths` — intersection of both when non-nil; `nil` when both nil; non-nil side when one is nil
    - `repair_approval` — per-key merge over full strategy set (missing = :always_deny); more restrictive wins per key
    - `metadata` — deep merge (override wins per key)
  """
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = base, %__MODULE__{} = override) do
    # Merge deny_globs (union) and allow_paths (nil = no restriction, [] = allow nothing)
    merged_deny = Enum.uniq(base.deny_globs ++ override.deny_globs)
    merged_allow = merge_allow_paths(base.allow_paths, override.allow_paths)

    # Repair approval: more restrictive approval mode wins per-key
    # Iterate over the full strategy set; missing entries default to :always_deny
    merged_repair =
      for strategy <- [:retry, :fallback, :patch, :human], into: %{} do
        base_mode = Map.get(base.repair_approval, strategy, :always_deny)
        override_mode = Map.get(override.repair_approval, strategy, :always_deny)
        {strategy, pick_more_restrictive_approval(base_mode, override_mode)}
      end

    # Metadata: deep merge with override winning
    merged_metadata = Map.merge(base.metadata, override.metadata)

    # Security dimensions: pick the MORE restrictive value
    merged_approval = more_restrictive_approval(base.approval_mode, override.approval_mode)
    merged_sandbox = more_restrictive_sandbox(base.sandbox_profile, override.sandbox_profile)
    merged_mcp = more_restrictive_mcp(base.mcp_trust, override.mcp_trust)
    merged_remote = more_restrictive_remote(base.remote_trust, override.remote_trust)

    %{
      base
      | approval_mode: merged_approval,
        sandbox_profile: merged_sandbox,
        deny_globs: merged_deny,
        allow_paths: merged_allow,
        mcp_trust: merged_mcp,
        remote_trust: merged_remote,
        repair_approval: merged_repair,
        metadata: merged_metadata
    }
  end

  # More restrictive = lower approval_ranking
  defp more_restrictive_approval(a, b) do
    if approval_ranking(a) <= approval_ranking(b), do: a, else: b
  end

  # Per-key repair approval merge: pick the more restrictive mode
  defp pick_more_restrictive_approval(a, b) do
    if approval_ranking(a) <= approval_ranking(b), do: a, else: b
  end

  # More restrictive sandbox: use proper subset semantics, fall to :locked_down if incomparable
  defp more_restrictive_sandbox(a, b) when a == b, do: a

  defp more_restrictive_sandbox(:unrestricted, b), do: b
  defp more_restrictive_sandbox(a, :unrestricted), do: a
  defp more_restrictive_sandbox(:locked_down, _b), do: :locked_down
  defp more_restrictive_sandbox(_a, :locked_down), do: :locked_down

  defp more_restrictive_sandbox(a, b) do
    cond do
      sandbox_strict_subset?(a, b) -> b
      sandbox_strict_subset?(b, a) -> a
      true -> :locked_down
    end
  end

  # True subset relationships between sandbox profiles:
  #   unrestricted < workspace_only < read_only < locked_down
  #   unrestricted < workspace_only < no_network < locked_down
  #   read_only and no_network are INCOMPARABLE
  defp sandbox_strict_subset?(:unrestricted, _), do: true
  defp sandbox_strict_subset?(:workspace_only, :read_only), do: true
  defp sandbox_strict_subset?(:workspace_only, :no_network), do: true
  defp sandbox_strict_subset?(:read_only, :locked_down), do: true
  defp sandbox_strict_subset?(:no_network, :locked_down), do: true
  defp sandbox_strict_subset?(_, _), do: false

  # allow_paths merge: nil means "no restriction", [] means "allow nothing"
  defp merge_allow_paths(nil, nil), do: nil
  defp merge_allow_paths(nil, paths), do: paths
  defp merge_allow_paths(paths, nil), do: paths
  defp merge_allow_paths(base, override), do: Enum.filter(base, &(&1 in override))

  # More restrictive = lower risk_index (fewer categories allowed)
  defp more_restrictive_mcp(a, b) do
    if Classification.risk_index(a) <= Classification.risk_index(b), do: a, else: b
  end

  # More restrictive = higher trust_ranking (requires more trust)
  defp more_restrictive_remote(a, b) do
    if TrustBoundary.trust_ranking(a) >= TrustBoundary.trust_ranking(b), do: a, else: b
  end

  # --- Validators ---

  defp validate_approval_mode(mode) when mode in @approval_modes, do: :ok
  defp validate_approval_mode(mode), do: {:error, {:invalid_approval_mode, mode}}

  defp validate_sandbox_profile(profile) when profile in @sandbox_profiles, do: :ok
  defp validate_sandbox_profile(profile), do: {:error, {:invalid_sandbox_profile, profile}}

  defp validate_glob_list(nil, :allow_paths), do: :ok

  defp validate_glob_list(list, field) when is_list(list) do
    if Enum.all?(list, &is_binary/1) do
      :ok
    else
      {:error, {:invalid_glob_list, field}}
    end
  end

  defp validate_glob_list(_, field), do: {:error, {:invalid_glob_list, field}}

  defp validate_mcp_trust(trust) do
    if trust in Classification.categories(), do: :ok, else: {:error, {:invalid_mcp_trust, trust}}
  end

  defp validate_remote_trust(trust) do
    if trust in TrustBoundary.trust_levels(),
      do: :ok,
      else: {:error, {:invalid_remote_trust, trust}}
  end

  defp validate_repair_approval(map) when is_map(map) do
    valid_strategies = [:retry, :fallback, :patch, :human]

    invalid_keys =
      map
      |> Map.keys()
      |> Enum.reject(&(&1 in valid_strategies))

    if invalid_keys == [] and Enum.all?(Map.values(map), &(&1 in @approval_modes)) do
      :ok
    else
      {:error, {:invalid_repair_approval, invalid_keys}}
    end
  end

  defp validate_repair_approval(_), do: {:error, {:invalid_repair_approval, :not_a_map}}

  defp validate_metadata(meta) when is_map(meta), do: :ok
  defp validate_metadata(_), do: {:error, :invalid_metadata}
end
