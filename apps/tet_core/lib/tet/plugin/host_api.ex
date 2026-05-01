defmodule Tet.Plugin.HostAPI do
  @moduledoc """
  Constrained host API that checks manifest-declared capabilities before acting.

  BD-0051 requires that plugins go through capability-gated API functions rather
  than calling BEAM primitives directly (e.g. `System.cmd/3`, `File.write!/2`).

  ## Trust model limitations

  **WARNING:** The BEAM provides no OS-level sandbox. A malicious plugin can
  still call `System.cmd/3`, `File.write!/2`, `Process.exit/1`, etc. directly
  because it runs in the same VM. The capability gates in this module only
  control access when plugins voluntarily use this API.

  For true isolation in production:
  - Run untrusted plugins in separate OS processes
  - Use containerization (Docker, Firecracker, etc.)
  - Apply BEAM node-level isolation with restricted nodes
  - Audit plugin source before loading

  This module is the *honest* path — compliant plugins use it, but the
  architecture does not prevent malicious code.
  """

  alias Tet.Plugin.Manifest

  @doc """
  Executes a shell command if the plugin has `:shell` capability.

  Returns `{collected_output, exit_status}` on success, or
  `{:error, {:unauthorized_capability, :shell}}` when the plugin lacks
  the `:shell` capability.
  """
  @spec shell_cmd(Manifest.t(), binary(), [binary()], keyword()) ::
          {binary(), exit_status :: non_neg_integer()} | {:error, term()}
  def shell_cmd(%Manifest{} = manifest, cmd, args, opts \\ []) do
    Tet.Plugin.Capability.gate(manifest, :shell, fn ->
      System.cmd(cmd, args, opts)
    end)
  end

  @doc """
  Writes content to a file if the plugin has `:file_access` capability.

  Returns `:ok` on success, or `{:error, {:unauthorized_capability, :file_access}}`
  when the plugin lacks the `:file_access` capability.
  """
  @spec file_write(Manifest.t(), Path.t(), iodata(), keyword()) ::
          :ok | {:error, term()}
  def file_write(%Manifest{} = manifest, path, content, opts \\ []) do
    Tet.Plugin.Capability.gate(manifest, :file_access, fn ->
      File.write(path, content, opts)
    end)
  end

  @doc """
  Reads a file if the plugin has `:file_access` capability.

  Returns `{:ok, binary}` on success, or `{:error, reason}`.
  """
  @spec file_read(Manifest.t(), Path.t()) :: {:ok, binary()} | {:error, term()}
  def file_read(%Manifest{} = manifest, path) do
    Tet.Plugin.Capability.gate(manifest, :file_access, fn ->
      File.read(path)
    end)
  end

  @doc """
  Makes an HTTP request if the plugin has `:network` capability.

  Returns `{:ok, %HTTPoison.Response{}}` or `{:error, reason}`.
  """
  @spec http_request(Manifest.t(), :get | :post | :put | :delete, binary(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def http_request(%Manifest{} = manifest, method, url, opts \\ []) do
    Tet.Plugin.Capability.gate(manifest, :network, fn ->
      # Use :httpc from inets for stdlib-only HTTP
      request = build_request(method, url, opts)

      case :httpc.request(request) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  Executes a tool call via the plugin's entrypoint if it has `:tool_execution` capability.

  This delegates to the plugin's `handle_tool_call/2` callback.
  """
  @spec execute_tool(Manifest.t(), map()) :: {:ok, term()} | {:error, term()}
  def execute_tool(%Manifest{} = manifest, args) do
    Tet.Plugin.Capability.gate(manifest, :tool_execution, fn ->
      apply(manifest.entrypoint, :handle_tool_call, [manifest, args])
    end)
  end

  # -- Private --

  defp build_request(:get, url, _opts), do: {:get, url, []}
  defp build_request(:post, url, opts), do: {:post, url, Keyword.get(opts, :body, ""), []}
  defp build_request(:put, url, opts), do: {:put, url, Keyword.get(opts, :body, ""), []}
  defp build_request(:delete, url, _opts), do: {:delete, url, []}
end
