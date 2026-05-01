defmodule Tet.Remote.TrustBoundary do
  @moduledoc """
  Trust boundary model for remote execution — BD-0053.

  Every remote connection runs in a trust context that determines what
  operations are allowed and which secrets are accessible. This module
  makes the trust boundary *explicit* — no "let's just try it and see"
  hand-waving.

  ## Trust levels

    - `:local` — Full trust. All operations, all secrets. The local machine
      is the security anchor; if you can't trust local, you've already lost.

    - `:trusted_remote` — A remote host whose identity you've pinned and
      whose environment you've scoped. Shell commands run under sandbox
      policy; only secrets explicitly scoped to `:trusted_remote` are
      available; no raw credential forwarding.

    - `:untrusted_remote` — Maximum paranoia. Read-only operations only.
      No secret access whatsoever. Useful for "can this host even respond?"
      health checks and version probes.

  ## Secret scoping

  Secrets are not ambient. A secret reference must declare which trust
  levels may resolve it. A `:trusted_remote` connection can only see
  secrets tagged `:trusted_remote` or `:local`. An `:untrusted_remote`
  connection sees nothing — period.

  ## Operations

  Operations are grouped by minimum trust level. Attempting an operation
  below the required trust level returns `{:error, {:trust_violation, _}}`.
  """

  alias Tet.Remote.SSHProfile

  @trust_levels [:local, :trusted_remote, :untrusted_remote]
  # --- Types ---

  @type trust_level :: :local | :trusted_remote | :untrusted_remote
  @type operation :: atom()

  @type secret_scope :: %{
          ref: binary(),
          min_trust: trust_level()
        }

  # --- Trust level queries ---

  @doc "Returns all defined trust levels in descending trust order."
  @spec trust_levels() :: [trust_level()]
  def trust_levels, do: @trust_levels

  @doc "Returns the numeric trust ranking (higher = more trusted)."
  @spec trust_ranking(trust_level()) :: non_neg_integer()
  def trust_ranking(:local), do: 3
  def trust_ranking(:trusted_remote), do: 2
  def trust_ranking(:untrusted_remote), do: 1

  @doc "Returns true when `level` is a valid trust level."
  @spec valid_trust_level?(term()) :: boolean()
  def valid_trust_level?(level) when level in @trust_levels, do: true
  def valid_trust_level?(_), do: false

  @doc "Returns true when `level` meets or exceeds the `required` trust."
  @spec trusts_at_least?(trust_level(), trust_level()) :: boolean()
  def trusts_at_least?(level, required)
      when level in [:local, :trusted_remote, :untrusted_remote] and
             required in [:local, :trusted_remote, :untrusted_remote] do
    trust_ranking(level) >= trust_ranking(required)
  end

  def trusts_at_least?(_level, _required), do: false

  # --- Operation gates ---

  @local_only_operations [:write_files, :install_packages, :full_shell, :manage_services]
  @trusted_remote_operations [
    :execute_commands,
    :read_files,
    :write_scoped_files,
    :deploy_releases
  ]
  @untrusted_remote_operations [:read_status, :check_version, :heartbeat_check]

  @doc "Operations that require `:local` trust or above."
  @spec local_only_operations() :: [operation()]
  def local_only_operations, do: @local_only_operations

  @doc "Operations available at `:trusted_remote` trust or above."
  @spec trusted_remote_operations() :: [operation()]
  def trusted_remote_operations, do: @trusted_remote_operations

  @doc "Operations available even at `:untrusted_remote` trust."
  @spec untrusted_remote_operations() :: [operation()]
  def untrusted_remote_operations, do: @untrusted_remote_operations

  @doc "Returns the minimum trust level required for an operation."
  @spec minimum_trust_for(operation()) :: {:ok, trust_level()} | {:error, :unknown_operation}
  def minimum_trust_for(operation) when operation in @untrusted_remote_operations,
    do: {:ok, :untrusted_remote}

  def minimum_trust_for(operation) when operation in @trusted_remote_operations,
    do: {:ok, :trusted_remote}

  def minimum_trust_for(operation) when operation in @local_only_operations,
    do: {:ok, :local}

  def minimum_trust_for(_operation), do: {:error, :unknown_operation}

  @doc """
  Checks whether an operation is allowed at a given trust level.

  Returns `:ok` if allowed, `{:error, {:trust_violation, details}}` otherwise.
  """
  @spec check_operation(trust_level(), operation()) :: :ok | {:error, term()}
  def check_operation(trust_level, _operation) when trust_level not in @trust_levels do
    {:error, {:invalid_trust_level, trust_level}}
  end

  def check_operation(trust_level, operation) when trust_level in @trust_levels do
    case minimum_trust_for(operation) do
      {:ok, required} ->
        if trusts_at_least?(trust_level, required) do
          :ok
        else
          {:error,
           {:trust_violation, %{operation: operation, required: required, actual: trust_level}}}
        end

      {:error, :unknown_operation} ->
        {:error, {:unknown_operation, operation}}
    end
  end

  # --- Secret scoping ---

  @doc """
  Checks whether a secret reference is accessible at a given trust level.

  A secret is accessible when its `min_trust` is at or below the
  connection's trust level. Untrusted remotes see *nothing*.
  """
  @spec check_secret_access(trust_level(), secret_scope()) ::
          :ok | {:error, term()}
  def check_secret_access(trust_level, _secret_scope) when trust_level not in @trust_levels do
    {:error, {:secret_access_denied, {:invalid_trust_level, trust_level}}}
  end

  def check_secret_access(:untrusted_remote, _secret_scope),
    do: {:error, {:secret_access_denied, :untrusted_remote_no_secrets}}

  def check_secret_access(_trust_level, %{min_trust: min_trust})
      when min_trust not in [:local, :trusted_remote, :untrusted_remote] do
    {:error, {:secret_access_denied, {:invalid_min_trust, min_trust}}}
  end

  def check_secret_access(trust_level, %{min_trust: min_trust} = _secret_scope) do
    if trusts_at_least?(trust_level, min_trust) do
      :ok
    else
      {:error, {:secret_access_denied, %{actual: trust_level, required: min_trust}}}
    end
  end

  def check_secret_access(_trust_level, _invalid_scope),
    do: {:error, {:secret_access_denied, :invalid_scope}}

  @doc """
  Filters a list of secret scopes to those accessible at a trust level.

  Returns only the refs that pass `check_secret_access/2`.
  """
  @spec accessible_secrets(trust_level(), [secret_scope()]) :: [secret_scope()]
  def accessible_secrets(trust_level, scopes) do
    Enum.filter(scopes, fn scope ->
      check_secret_access(trust_level, scope) == :ok
    end)
  end

  @doc """
  Derives the trust level from an SSH profile.

  This is a convenience function — the trust level is already on the
  profile. It exists to make the boundary between "where does trust
  come from?" and "what does trust allow?" crystal clear.
  """
  @spec from_profile(SSHProfile.t()) :: trust_level()
  def from_profile(%SSHProfile{trust_level: level}), do: level

  @doc """
  Summarizes the full trust boundary for a connection as a map.

  Useful for logging, telemetry, and debugging without leaking secrets.
  """
  @spec summarize(trust_level()) :: map()
  def summarize(trust_level) when trust_level in @trust_levels do
    %{
      trust_level: trust_level,
      trust_ranking: trust_ranking(trust_level),
      allowed_operations: allowed_operations_for(trust_level),
      secret_access: secret_access_description(trust_level)
    }
  end

  # --- Private ---

  defp allowed_operations_for(:local) do
    @untrusted_remote_operations ++ @trusted_remote_operations ++ @local_only_operations
  end

  defp allowed_operations_for(:trusted_remote) do
    @untrusted_remote_operations ++ @trusted_remote_operations
  end

  defp allowed_operations_for(:untrusted_remote) do
    @untrusted_remote_operations
  end

  defp secret_access_description(:local), do: :all_secrets
  defp secret_access_description(:trusted_remote), do: :scoped_secrets_only
  defp secret_access_description(:untrusted_remote), do: :no_secrets
end
