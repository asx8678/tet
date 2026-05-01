defmodule Tet.Plugin.Capability do
  @moduledoc """
  Known capability types, permission gating, and centralized metadata for plugins.

  BD-0051 defines a closed set of capability atoms that plugins may declare.
  The `authorized?/2` and `gate/2` functions enforce that a plugin can only
  exercise capabilities it has explicitly declared in its manifest.

  ## Known capabilities

    * `:tool_execution` — invoke tool contracts
    * `:file_access`    — read/write files on the host
    * `:network`        — make outbound network requests
    * `:shell`          — execute shell commands
    * `:mcp`            — interact with MCP (Model Context Protocol) servers

  ## Trust levels

  Trust levels gate the *maximum* capability set a plugin may hold:

    * `:sandboxed`   — may only use `:tool_execution`
    * `:restricted`  — may use `:tool_execution`, `:file_access`, `:mcp`
    * `:full`        — may declare any known capability

  If a plugin's manifest declares a capability not permitted by its trust
  level, validation fails at manifest-creation time.

  ## Trust model

  CAUTION: The plugin trust model currently relies on plugins self-attesting
  their `trust_level` and `capabilities`. In production deployments:
  - Trust levels should be explicitly granted by an external admin/config,
    not taken from the plugin manifest.
  - The runtime enforces the intersection of:
      requested capabilities ∩ trust ceiling ∩ admin-granted capabilities
  - Plugin code runs in the same BEAM VM with no sandbox. A malicious
    plugin CAN still call `System.cmd/3`, `File.write!/2`, etc. directly.
    The capability gates only control callback dispatch, not BEAM primitives.
    For true isolation, run plugins in a separate OS process or container.
  """

  @known_capabilities [:tool_execution, :file_access, :network, :shell, :mcp]

  @trust_ceiling %{
    sandboxed: [:tool_execution],
    restricted: [:tool_execution, :file_access, :mcp],
    full: @known_capabilities
  }

  @capability_callbacks %{
    tool_execution: :handle_tool_call,
    file_access: :handle_file_access,
    network: :handle_network_request,
    shell: :handle_shell_command,
    mcp: :handle_mcp_request
  }

  @type capability :: :tool_execution | :file_access | :network | :shell | :mcp
  @type trust_level :: :sandboxed | :restricted | :full

  @doc "Returns all known capability atoms."
  @spec known_capabilities() :: [capability()]
  def known_capabilities, do: @known_capabilities

  @doc "Returns the callback function name for a capability atom."
  @spec callback_for(capability()) :: atom()
  def callback_for(capability), do: @capability_callbacks[capability]

  @doc "Returns the full capability-to-callback map."
  @spec capability_callbacks() :: %{capability() => atom()}
  def capability_callbacks, do: @capability_callbacks

  @doc "Returns the maximum capabilities allowed for a trust level."
  @spec trust_ceiling(trust_level()) :: [capability()]
  def trust_ceiling(:sandboxed), do: @trust_ceiling[:sandboxed]
  def trust_ceiling(:restricted), do: @trust_ceiling[:restricted]
  def trust_ceiling(:full), do: @trust_ceiling[:full]

  @doc """
  Returns the effective capabilities granted to a plugin.

  Granted capabilities are the intersection of:
    1. What the plugin requested (declared in manifest `capabilities`)
    2. What the trust level allows (`trust_ceiling/1`)
    3. What the admin has explicitly granted (optional `admin_granted` list)

  If `admin_granted` is `nil`, only #1 and #2 are intersected.
  """
  @spec granted_capabilities(
          [capability()],
          trust_level(),
          [capability()] | nil
        ) :: [capability()]
  def granted_capabilities(requested, trust_level, admin_granted \\ nil) do
    ceiling = trust_ceiling(trust_level)

    base =
      if admin_granted do
        Enum.filter(requested, &(&1 in admin_granted))
      else
        requested
      end

    Enum.filter(base, &(&1 in ceiling))
  end

  @doc """
  Checks whether a plugin manifest is authorized to use a given capability.

  Returns `true` when the capability is in the manifest's `capabilities`
  list (which should be the *granted* set) and within the trust ceiling.

  ## Examples

      iex> manifest = Tet.Plugin.Manifest.new!(%{
      ...>   name: "demo", version: "1.0.0", capabilities: [:tool_execution],
      ...>   trust_level: :sandboxed, entrypoint: Demo.Plugin
      ...> })
      iex> Tet.Plugin.Capability.authorized?(manifest, :tool_execution)
      true
      iex> Tet.Plugin.Capability.authorized?(manifest, :network)
      false
  """
  @spec authorized?(Tet.Plugin.Manifest.t(), capability()) :: boolean()
  def authorized?(%Tet.Plugin.Manifest{} = manifest, capability) do
    capability in manifest.capabilities and
      capability in trust_ceiling(manifest.trust_level)
  end

  @doc """
  Wraps a capability-using function call with a permission gate.

  If the manifest is authorized for the given capability, executes `fun.()`.
  Otherwise returns `{:error, {:unauthorized_capability, capability}}`.

  ## Examples

      iex> manifest = Tet.Plugin.Manifest.new!(%{
      ...>   name: "demo", version: "1.0.0", capabilities: [:tool_execution],
      ...>   trust_level: :sandboxed, entrypoint: Demo.Plugin
      ...> })
      iex> Tet.Plugin.Capability.gate(manifest, :tool_execution, fn -> :ok end)
      :ok
      iex> Tet.Plugin.Capability.gate(manifest, :shell, fn -> :boom end)
      {:error, {:unauthorized_capability, :shell}}
  """
  @spec gate(Tet.Plugin.Manifest.t(), capability(), (-> term())) ::
          term() | {:error, {:unauthorized_capability, capability()}}
  def gate(%Tet.Plugin.Manifest{} = manifest, capability, fun)
      when is_function(fun, 0) do
    if capability in @known_capabilities and authorized?(manifest, capability) do
      fun.()
    else
      {:error, {:unauthorized_capability, capability}}
    end
  end

  @doc """
  Validates that all declared capabilities are within the trust ceiling.

  Returns `:ok` when every capability is permitted by the trust level, or
  `{:error, {:exceeds_trust, overflow}}` where `overflow` is the list of
  capabilities that exceed the trust level.

  ## Examples

      iex> Tet.Plugin.Capability.validate_for_trust([:tool_execution], :sandboxed)
      :ok

      iex> Tet.Plugin.Capability.validate_for_trust([:shell], :sandboxed)
      {:error, {:exceeds_trust, [:shell]}}
  """
  @spec validate_for_trust([capability()], trust_level()) ::
          :ok | {:error, {:exceeds_trust, [capability()]}}
  def validate_for_trust(capabilities, trust_level) do
    ceiling = trust_ceiling(trust_level)
    overflow = Enum.reject(capabilities, &(&1 in ceiling))

    if overflow == [] do
      :ok
    else
      {:error, {:exceeds_trust, overflow}}
    end
  end
end
