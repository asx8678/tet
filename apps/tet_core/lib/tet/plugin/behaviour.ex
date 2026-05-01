defmodule Tet.Plugin.Behaviour do
  @moduledoc """
  Callback interface for plugin entrypoint modules.

  BD-0051 defines optional capability callbacks that plugin modules may
  implement. Each callback receives the plugin's manifest and a request
  args map, and returns `{:ok, result}` or `{:error, reason}`.

  Plugins only need to implement callbacks for the capabilities they declare
  in their manifest. The loader's `validate/1` checks that declared
  capabilities have matching callback implementations.
  """

  @type manifest :: Tet.Plugin.Manifest.t()
  @type args :: map()
  @type result :: {:ok, term()} | {:error, term()}

  @doc "Handle a tool execution request."
  @callback handle_tool_call(manifest(), args()) :: result()

  @doc "Handle a file access request."
  @callback handle_file_access(manifest(), args()) :: result()

  @doc "Handle a network request."
  @callback handle_network_request(manifest(), args()) :: result()

  @doc "Handle a shell command request."
  @callback handle_shell_command(manifest(), args()) :: result()

  @doc "Handle an MCP (Model Context Protocol) request."
  @callback handle_mcp_request(manifest(), args()) :: result()

  @optional_callbacks [
    handle_tool_call: 2,
    handle_file_access: 2,
    handle_network_request: 2,
    handle_shell_command: 2,
    handle_mcp_request: 2
  ]
end
