defmodule Tet.SecurityPolicy.Evaluator do
  @moduledoc """
  Core policy evaluation logic — BD-0067.

  The evaluator implements the **deny-always-beats-allow** principle and
  provides the `check/3` entry point that every other module should call
  for policy decisions.

  ## Decision flow

  1. **Approval mode short-circuit** — `:always_deny` immediately blocks.
  2. **Deny glob check** — if any deny glob matches, the action is denied
     regardless of allow paths. Deny *always* wins.
  3. **Allow path check** — if the action matches an allow pattern and no
     deny glob matched, it's allowed.
  4. **Sandbox profile enforcement** — actions that violate sandbox
     constraints are denied.
  5. **MCP trust resolution** — tool categories above the configured MCP
     trust level require approval.
  6. **Remote trust resolution** — remote operations below the configured
     remote trust level are denied.
  7. **Repair approval resolution** — repair strategies require the mapped
     approval mode or higher.
  8. **Fail-closed default** — if none of the above explicitly allows, the
     action needs approval.

  ## Glob matching

  Globs use `fnmatch`-style matching via `:filelib.wildcard/2` semantics.
  Supported patterns:

    - `*` matches any single path segment
    - `**` matches zero or more path segments
    - `?` matches a single character

  Note: character classes `[...]` are NOT supported — brackets
  are escaped as literal characters by `Regex.escape/1`.

  We normalise and canonicalise paths (resolving `..` segments) before
  matching to prevent path-traversal bypass attacks.

  This module is pure data and pure functions. No side effects, no IO,
  no GenServer.
  """

  alias Tet.SecurityPolicy.Profile
  alias Tet.Mcp.Classification
  alias Tet.Remote.TrustBoundary

  # --- Types ---

  @type action :: atom() | String.t()
  @type context :: %{
          optional(:path) => String.t(),
          optional(:mcp_category) => Classification.category(),
          optional(:remote_operation) => atom(),
          optional(:remote_trust_level) => TrustBoundary.trust_level(),
          optional(:repair_strategy) => atom(),
          optional(:sandbox_path) => String.t(),
          optional(:workspace_root) => String.t(),
          optional(:task_category) => atom()
        }
  @type reason :: atom() | {atom(), map() | atom() | term()}
  @type decision ::
          :allowed
          | {:denied, reason()}
          | {:needs_approval, reason()}

  # --- Public API ---

  @doc """
  Evaluates (action, context, profile) → decision.

  The central policy evaluation function. Returns one of:

    - `:allowed` — the action is permitted.
    - `{:denied, reason}` — the action is forbidden.
    - `{:needs_approval, reason}` — the action requires explicit approval.

  ## Examples

      iex> profile = Tet.SecurityPolicy.Profile.default()
      iex> Tet.SecurityPolicy.Evaluator.check(:read, %{mcp_category: :read}, profile)
      {:needs_approval, :approval_mode_require_approve}

      iex> profile = Tet.SecurityPolicy.Profile.permissive()
      iex> Tet.SecurityPolicy.Evaluator.check(:read, %{mcp_category: :read}, profile)
      :allowed
  """
  @spec check(action(), context(), Profile.t()) :: decision()
  def check(_action, _context, %Profile{approval_mode: :always_deny}) do
    {:denied, :always_deny_mode}
  end

  def check(action, context, %Profile{} = profile) do
    # Normalize action to handle string inputs safely
    normalized_action = normalize_action(action)

    # Fail-closed: unknown actions are always denied
    if normalized_action == :unknown do
      {:denied, :unknown_action}
    else
      check_pipeline(normalized_action, action, context, profile)
    end
  end

  @doc """
  Batch-evaluates a list of actions against the same context and profile.

  Returns a list of `{action, decision}` tuples in input order.
  """
  @spec check_all([{action(), context()}], Profile.t()) :: [{action(), decision()}]
  def check_all(actions_with_context, %Profile{} = profile) when is_list(actions_with_context) do
    Enum.map(actions_with_context, fn {action, context} ->
      {action, check(action, context, profile)}
    end)
  end

  @doc """
  Checks whether a path is denied by deny globs.

  Returns `true` if any deny glob matches the path.
  """
  @spec denied_by_glob?(String.t(), [String.t()]) :: boolean()
  def denied_by_glob?(path, deny_globs) when is_binary(path) and is_list(deny_globs) do
    normalised = canonicalise_path(path)

    Enum.any?(deny_globs, fn glob ->
      case glob_match?(normalised, normalise_pattern(glob)) do
        {:ok, matches?} -> matches?
        {:error, _} -> true
      end
    end)
  end

  @doc """
  Checks whether a path is allowed by allow paths.

  Returns `true` if any allow path matches the path. Note: this does NOT
  check deny globs — the caller must check deny first.
  """
  @spec allowed_by_path?(String.t(), [String.t()]) :: boolean()
  def allowed_by_path?(path, allow_paths) when is_binary(path) and is_list(allow_paths) do
    normalised = canonicalise_path(path)

    Enum.any?(allow_paths, fn pattern ->
      case glob_match?(normalised, normalise_pattern(pattern)) do
        {:ok, matches?} -> matches?
        {:error, _} -> false
      end
    end)
  end

  @doc """
  Checks whether an MCP category is permitted by the profile's MCP trust level.

  Returns `:allowed`, `{:needs_approval, reason}`, or `{:denied, reason}`.
  """
  @spec check_mcp(Classification.category(), Profile.t()) :: decision()
  def check_mcp(category, %Profile{mcp_trust: mcp_trust}) do
    cond do
      category not in Classification.categories() ->
        {:denied, :unknown_mcp_category}

      Classification.risk_index(category) <= Classification.risk_index(mcp_trust) ->
        :allowed

      true ->
        {:needs_approval, {:mcp_trust_exceeded, %{category: category, max_allowed: mcp_trust}}}
    end
  end

  @doc """
  Checks whether a remote operation is permitted by the profile's remote trust level.
  """
  @spec check_remote(atom(), TrustBoundary.trust_level(), Profile.t()) :: decision()
  def check_remote(operation, actual_trust, %Profile{remote_trust: remote_trust}) do
    cond do
      not TrustBoundary.valid_trust_level?(actual_trust) ->
        {:denied, :invalid_remote_trust_level}

      not TrustBoundary.trusts_at_least?(actual_trust, remote_trust) ->
        {:denied, {:remote_trust_insufficient, %{required: remote_trust, actual: actual_trust}}}

      true ->
        case TrustBoundary.check_operation(actual_trust, operation) do
          :ok -> :allowed
          {:error, {:trust_violation, details}} -> {:denied, {:remote_trust_violation, details}}
          {:error, {:unknown_operation, op}} -> {:denied, {:unknown_remote_operation, op}}
        end
    end
  end

  @doc """
  Checks whether a sandbox profile permits an operation on a path.

  Sandbox constraints:

    - `:unrestricted` — no constraints.
    - `:workspace_only` — path must be under workspace root.
    - `:read_only` — path must be under workspace root and action must be read.
    - `:no_network` — network actions are denied (filesystem follows workspace_only).
    - `:locked_down` — all filesystem and network actions are denied.
  """
  @spec check_sandbox(action(), context(), Profile.t()) :: decision()
  def check_sandbox(_action, _context, %Profile{sandbox_profile: :unrestricted}), do: :allowed

  def check_sandbox(_action, _context, %Profile{sandbox_profile: :locked_down}) do
    {:denied, :sandbox_locked_down}
  end

  def check_sandbox(action, context, %Profile{sandbox_profile: :no_network}) do
    norm = normalize_action(action)

    if network_action?(norm, context) do
      {:denied, :sandbox_no_network}
    else
      # Filesystem follows workspace_only rules
      check_sandbox_workspace(context)
    end
  end

  def check_sandbox(action, context, %Profile{sandbox_profile: :read_only}) do
    norm = normalize_action(action)
    path = effective_path(context)
    workspace = Map.get(context, :workspace_root, "/workspace")

    cond do
      mutation_action?(norm, context) ->
        {:denied, :sandbox_read_only}

      is_binary(path) and not path_under_workspace?(path, workspace) ->
        {:denied, :sandbox_workspace_only}

      true ->
        :allowed
    end
  end

  def check_sandbox(_action, context, %Profile{sandbox_profile: :workspace_only}) do
    check_sandbox_workspace(context)
  end

  defp check_sandbox_workspace(context) do
    path = effective_path(context)
    workspace = Map.get(context, :workspace_root, "/workspace")

    if is_binary(path) and not path_under_workspace?(path, workspace) do
      {:denied, :sandbox_workspace_only}
    else
      :allowed
    end
  end

  @doc """
  Checks whether a repair strategy is permitted by the profile's repair approval mapping.

  The effective approval gate is the **more restrictive** of the profile's global
  `approval_mode` and the strategy-specific `repair_approval` entry. This ensures
  that a repair strategy requiring `:require_approve` still needs approval even
  when the global mode is `:auto_approve`.
  """
  @spec check_repair(atom(), Profile.t()) :: decision()
  def check_repair(strategy, %Profile{repair_approval: repair_approval, approval_mode: mode}) do
    required = Map.get(repair_approval, strategy, :always_deny)

    cond do
      strategy not in [:retry, :fallback, :patch, :human] ->
        {:denied, :unknown_repair_strategy}

      mode == :always_deny ->
        {:denied, :always_deny_mode}

      required == :always_deny ->
        {:denied, {:repair_always_deny, strategy}}

      true ->
        # More restrictive of (global mode, repair required) wins
        # Lower approval_ranking = more restrictive
        effective_ranking =
          min(Profile.approval_ranking(mode), Profile.approval_ranking(required))

        case effective_ranking do
          3 ->
            :allowed

          2 ->
            {:needs_approval, :suggest_approve}

          1 ->
            {:needs_approval,
             {:repair_approval_required, %{strategy: strategy, required: required}}}

          _ ->
            {:denied, :always_deny_mode}
        end
    end
  end

  @doc """
  Checks the approval mode directly.

    - `:auto_approve` → `:allowed`
    - `:suggest_approve` → `{:needs_approval, :suggest_approve}`
    - `:require_approve` → `{:needs_approval, :approval_mode_require_approve}`
    - `:always_deny` → `{:denied, :always_deny_mode}` (handled by check/3 short-circuit)
  """
  @spec check_approval_mode(Profile.approval_mode()) :: decision()
  def check_approval_mode(:auto_approve), do: :allowed
  def check_approval_mode(:suggest_approve), do: {:needs_approval, :suggest_approve}
  def check_approval_mode(:require_approve), do: {:needs_approval, :approval_mode_require_approve}
  def check_approval_mode(:always_deny), do: {:denied, :always_deny_mode}

  # --- Private: evaluation pipeline ---

  defp check_pipeline(normalized_action, _raw_action, context, profile) do
    # 1. Approval mode gate
    case check_approval_mode(profile.approval_mode) do
      {:denied, _} = denied ->
        denied

      {:needs_approval, _} = needs ->
        maybe_continue_after_approval(needs, normalized_action, context, profile)

      :allowed ->
        evaluate_dimensions(normalized_action, context, profile)
    end
  end

  defp maybe_continue_after_approval({:needs_approval, _} = needs, _action, _context, %Profile{
         approval_mode: :auto_approve
       }) do
    # auto_approve means we continue evaluating dimensions even though
    # base mode is less permissive — nope, auto_approve is already :allowed above.
    # This clause is unreachable but kept for clarity.
    needs
  end

  defp maybe_continue_after_approval({:needs_approval, _} = needs, action, context, profile) do
    # Even if approval mode says "needs approval", we still check dimensions
    # to see if a hard denial applies. A hard deny overrides "needs approval".
    # If a dimension returns a stricter needs_approval, use that instead.
    case evaluate_dimensions(action, context, profile) do
      {:denied, _} = denied -> denied
      {:needs_approval, _} = dim_needs -> stricter_approval(needs, dim_needs)
      :allowed -> needs
    end
  end

  defp evaluate_dimensions(action, context, profile) do
    results = [
      check_deny_allow(action, context, profile),
      check_sandbox_dimension(action, context, profile),
      check_mcp_dimension(action, context, profile),
      check_remote_dimension(action, context, profile),
      check_repair_dimension(action, context, profile)
    ]

    # First denial wins, then strictest needs_approval, else allowed
    case Enum.find(results, &match?({:denied, _}, &1)) do
      {:denied, _} = denied ->
        denied

      nil ->
        approvals = for {:needs_approval, _} = a <- results, do: a

        case pick_strictest_approval(approvals) do
          nil -> :allowed
          strictest -> strictest
        end
    end
  end

  defp check_deny_allow(_action, context, profile) do
    path = effective_path(context)

    # Deny globs always win
    if is_binary(path) and denied_by_glob?(path, profile.deny_globs) do
      {:denied, :denied_by_glob}
    else
      # Check allow paths: nil means "no restriction", [] means "allow nothing"
      if is_binary(path) and profile.allow_paths != nil do
        if allowed_by_path?(path, profile.allow_paths) do
          :allowed
        else
          {:needs_approval, :not_in_allow_paths}
        end
      else
        :allowed
      end
    end
  end

  defp check_sandbox_dimension(action, context, profile) do
    check_sandbox(action, context, profile)
  end

  defp check_mcp_dimension(_action, context, profile) do
    case Map.fetch(context, :mcp_category) do
      {:ok, category} when is_atom(category) ->
        if category in Classification.categories() do
          check_mcp(category, profile)
        else
          {:denied, :unknown_mcp_category}
        end

      {:ok, _} ->
        {:denied, :unknown_mcp_category}

      :error ->
        :allowed
    end
  end

  defp check_remote_dimension(_action, context, profile) do
    case {Map.fetch(context, :remote_operation), Map.fetch(context, :remote_trust_level)} do
      {{:ok, op}, {:ok, trust}} when is_atom(op) and is_atom(trust) ->
        check_remote(op, trust, profile)

      {{:ok, _}, :error} ->
        {:denied, :missing_remote_trust_level}

      {:error, {:ok, _}} ->
        {:denied, :missing_remote_operation}

      {{:ok, _}, {:ok, _}} ->
        {:denied, :invalid_remote_context}

      {:error, :error} ->
        :allowed
    end
  end

  defp check_repair_dimension(action, context, profile) do
    strategy = Map.get(context, :repair_strategy)

    cond do
      is_atom(strategy) and not is_nil(strategy) and strategy not in [true, false] ->
        check_repair(strategy, profile)

      action == :repair ->
        # Action is repair but no valid strategy provided — deny
        {:denied, :missing_repair_strategy}

      Map.has_key?(context, :repair_strategy) ->
        # repair_strategy was provided but is invalid (nil, string, boolean, etc.)
        {:denied, :invalid_repair_strategy}

      true ->
        :allowed
    end
  end

  # --- Private: glob matching ---

  defp glob_match?(path, pattern) do
    regex = glob_to_regex(pattern)

    case Regex.compile(regex) do
      {:ok, compiled} -> {:ok, Regex.match?(compiled, path)}
      {:error, _} -> {:error, :invalid_glob}
    end
  end

  defp glob_to_regex(pattern) do
    # Pre-process ** patterns with their surrounding / context
    # Absorb the / separators into the marker so we avoid double-slash issues
    processed =
      pattern
      |> String.replace("/**/", "\x00MID\x00")
      |> String.replace("/**", "/\x00END\x00")
      |> String.replace("**/", "\x00BEG\x00")
      |> String.replace("**", "\x00ALL\x00")

    # Split on our markers and remaining glob chars
    parts =
      Regex.split(
        ~r/(\x00MID\x00|\x00END\x00|\x00BEG\x00|\x00ALL\x00|\*|\?)/,
        processed,
        include_captures: true
      )

    regex_parts =
      Enum.map(parts, fn
        # /**/ — / then zero or more intermediate segments
        "\x00MID\x00" -> "/(?:.+/)?"
        # /** at end — everything under
        "\x00END\x00" -> ".*"
        # **/ at start — zero or more leading segments
        "\x00BEG\x00" -> "(?:.*/)?"
        # standalone ** — match everything
        "\x00ALL\x00" -> ".*"
        # single segment
        "*" -> "[^/]*"
        # single char (not /)
        "?" -> "[^/]"
        # escape regex metacharacters
        literal -> Regex.escape(literal)
      end)

    "^" <> Enum.join(regex_parts, "") <> "$"
  end

  defp normalise_path(path) do
    path
    |> String.replace("\\", "/")
    |> String.trim_trailing("/")
  end

  # Canonicalise path: lexical segment normalisation to resolve `.` and `..`
  # without touching the filesystem (pure, no Path.expand).
  defp canonicalise_path(path) do
    normalised = normalise_path(path)
    absolute? = String.starts_with?(normalised, "/")

    segments =
      normalised
      |> String.split("/")
      |> resolve_segments(absolute?)

    resolved = Enum.join(segments, "/")

    cond do
      absolute? and resolved == "" -> "/"
      absolute? -> "/" <> resolved
      true -> resolved
    end
  end

  # Resolve `.` and `..` segments without touching the filesystem.
  # For absolute paths, `..` at the root is clamped (you can't go above `/`).
  # For relative paths, leading `..` segments are preserved so that
  # `../secrets/key` does NOT collapse to `secrets/key` (which would
  # incorrectly match an allow rule like `secrets/**`).
  defp resolve_segments(segments, absolute?) do
    Enum.reduce(segments, [], fn
      "", acc -> acc
      ".", acc -> acc
      "..", [] when absolute? -> []
      "..", [] -> [".."]
      "..", [".." | _] = acc when not absolute? -> [".." | acc]
      "..", [_ | rest] -> rest
      segment, acc -> [segment | acc]
    end)
    |> Enum.reverse()
  end

  defp normalise_pattern(pattern) do
    pattern
    |> String.replace("\\", "/")
    |> String.trim_trailing("/")
  end

  # --- Private: workspace path check ---

  defp path_under_workspace?(path, workspace_root) do
    root = workspace_root |> Path.expand() |> canonicalise_path()

    expanded =
      if Path.type(path) == :absolute do
        Path.expand(path)
      else
        Path.expand(path, root)
      end
      |> canonicalise_path()

    expanded == root or String.starts_with?(expanded, root <> "/")
  end

  # --- Private: effective path ---

  defp effective_path(context) do
    Map.get(context, :sandbox_path) || Map.get(context, :path)
  end

  # --- Private: action normalization ---

  @safe_actions [
    :read,
    :write,
    :create,
    :delete,
    :patch,
    :modify,
    :update,
    :remove,
    :save,
    :insert,
    :add,
    :set,
    :put,
    :rename,
    :move,
    :copy,
    :execute,
    :exec,
    :run,
    :shell,
    :deploy,
    :tool,
    :repair,
    :network,
    :fetch,
    :http_request,
    :connect,
    :download,
    :upload
  ]

  @doc false
  @spec normalize_action(atom() | String.t()) :: atom()
  def normalize_action(action) when is_atom(action) do
    if action in @safe_actions, do: action, else: :unknown
  end

  def normalize_action(action) when is_binary(action) do
    atom = String.to_existing_atom(action)

    if atom in @safe_actions, do: atom, else: :unknown
  rescue
    ArgumentError -> :unknown
  end

  def normalize_action(_), do: :unknown

  # --- Private: network action check ---

  defp network_action?(action, context) do
    action in [:network, :fetch, :http_request, :connect, :download, :upload] or
      Map.get(context, :mcp_category) == :network or
      Map.has_key?(context, :remote_operation)
  end

  # --- Private: mutation action check ---

  @mutation_actions [
    :write,
    :create,
    :delete,
    :patch,
    :modify,
    :update,
    :remove,
    :save,
    :insert,
    :add,
    :set,
    :put,
    :rename,
    :move,
    :copy,
    :execute,
    :exec,
    :run,
    :shell,
    :deploy
  ]
  @mutation_mcp_categories [:write, :shell, :network, :admin]

  defp mutation_action?(action, context) do
    # Treat unknown actions as mutations (fail-closed)
    action == :unknown or
      action in @mutation_actions or
      (Map.has_key?(context, :mcp_category) and
         Map.get(context, :mcp_category) in @mutation_mcp_categories)
  end

  # --- Private: approval severity ---

  defp pick_strictest_approval([]), do: nil

  defp pick_strictest_approval(approvals) do
    Enum.min_by(approvals, &approval_severity/1)
  end

  # Lower severity = stricter
  defp approval_severity({:needs_approval, :suggest_approve}), do: 2
  defp approval_severity({:needs_approval, _}), do: 1

  defp stricter_approval(a, b) do
    if approval_severity(a) <= approval_severity(b), do: a, else: b
  end
end
