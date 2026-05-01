defmodule Tet.Plugin.Capability do
  @moduledoc """
  Known capability types and permission gating for plugins.

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
  """

  @known_capabilities [:tool_execution, :file_access, :network, :shell, :mcp]

  @trust_ceiling %{
    sandboxed: [:tool_execution],
    restricted: [:tool_execution, :file_access, :mcp],
    full: @known_capabilities
  }

  @type capability :: :tool_execution | :file_access | :network | :shell | :mcp
  @type trust_level :: :sandboxed | :restricted | :full

  @doc "Returns all known capability atoms."
  @spec known_capabilities() :: [capability()]
  def known_capabilities, do: @known_capabilities

  @doc "Returns the maximum capabilities allowed for a trust level."
  @spec trust_ceiling(trust_level()) :: [capability()]
  def trust_ceiling(:sandboxed), do: @trust_ceiling[:sandboxed]
  def trust_ceiling(:restricted), do: @trust_ceiling[:restricted]
  def trust_ceiling(:full), do: @trust_ceiling[:full]

  @doc """
  Checks whether a plugin manifest is authorized to use a given capability.

  Returns `true` when the capability is both declared in the manifest's
  `capabilities` list *and* permitted by the manifest's `trust_level`.

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
      when capability in @known_capabilities and is_function(fun, 0) do
    if authorized?(manifest, capability) do
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
