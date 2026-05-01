defmodule Tet.Mcp.ToolAdapter do
  @moduledoc """
  Adapter that converts raw MCP tool descriptors into `Tet.Mcp.Tool` structs.

  MCP servers expose tool descriptors as plain maps (from JSON-RPC `tools/list`).
  This adapter is the single place that knows how to:
    - Namespace a raw tool name under its server id.
    - Convert a descriptor map into a validated `Tet.Mcp.Tool` struct.
    - Parse a namespaced name back into its components.

  ## Namespace format

  All MCP tool names are namespaced as `mcp:<server_id>:<original_name>`.

  Neither `server_id` nor `original_name` may contain `:` — this guarantees
  that the three-part format is unambiguous and reversible.

  ## Examples

      iex> Tet.Mcp.ToolAdapter.namespaced_name("fs", "read_file")
      "mcp:fs:read_file"

      iex> Tet.Mcp.ToolAdapter.server_id("mcp:fs:read_file")
      {:ok, "fs"}

      iex> Tet.Mcp.ToolAdapter.original_name("mcp:fs:read_file")
      {:ok, "read_file"}
  """

  alias Tet.Mcp.Classification
  alias Tet.Mcp.Tool

  @namespace_prefix "mcp:"
  @namespace_separator ":"

  @doc """
  Produces the namespaced tool name: `mcp:<server_id>:<tool_name>`.

  Rejects server_id or tool_name containing `:` to keep the format unambiguous.
  """
  @spec namespaced_name(binary(), binary()) :: binary() | {:error, term()}
  def namespaced_name(server_id, tool_name)
      when is_binary(server_id) and is_binary(tool_name) do
    with :ok <- reject_colon(server_id, :server_id),
         :ok <- reject_colon(tool_name, :tool_name),
         :ok <- reject_empty(server_id, :server_id),
         :ok <- reject_empty(tool_name, :tool_name) do
      @namespace_prefix <> server_id <> @namespace_separator <> tool_name
    end
  end

  def namespaced_name(_, _), do: {:error, :invalid_args}

  @doc """
  Converts a raw MCP tool descriptor into a `Tet.Mcp.Tool` struct.

  The descriptor must include `"name"` (the original tool name). The
  `server_id` is provided separately (from the MCP server config).

  Optional descriptor fields:
    - `"description"` — human-readable description
    - `"inputSchema"` or `"input_schema"` — JSON Schema for tool input

  Classification is derived from the tool name via `Tet.Mcp.Classification`.
  An explicit `"mcp_category"` in the descriptor can upgrade (never downgrade)
  the heuristic classification.
  """
  @spec to_tool(binary(), map(), keyword()) :: {:ok, Tool.t()} | {:error, term()}
  def to_tool(server_id, descriptor, opts \\ [])

  def to_tool(server_id, descriptor, opts)
      when is_binary(server_id) and is_map(descriptor) do
    original_name = fetch_descriptor_name(descriptor)

    with {:ok, original_name} <- validate_name(original_name),
         :ok <- reject_colon(server_id, :server_id),
         :ok <- reject_colon(original_name, :tool_name),
         {:ok, namespaced} <- wrap_namespaced(namespaced_name(server_id, original_name)) do
      classification =
        descriptor
        |> maybe_with_category(opts)
        |> Classification.classify()

      Tool.new(%{
        name: namespaced,
        server_id: server_id,
        original_name: original_name,
        description: fetch_descriptor_field(descriptor, "description", ""),
        input_schema: fetch_descriptor_field(descriptor, "inputSchema", %{}),
        classification: classification,
        annotations: build_annotations(descriptor)
      })
    end
  end

  def to_tool(_, _, _), do: {:error, :invalid_args}

  @doc """
  Extracts the server_id from a namespaced tool name.

  Returns `{:ok, server_id}` or `{:error, reason}`.
  """
  @spec server_id(binary()) :: {:ok, binary()} | {:error, term()}
  def server_id(name) when is_binary(name) do
    case parse_namespaced(name) do
      {:ok, server_id, _original} -> {:ok, server_id}
      error -> error
    end
  end

  def server_id(_), do: {:error, :invalid_name}

  @doc """
  Extracts the original tool name from a namespaced tool name.

  Returns `{:ok, original_name}` or `{:error, reason}`.
  """
  @spec original_name(binary()) :: {:ok, binary()} | {:error, term()}
  def original_name(name) when is_binary(name) do
    case parse_namespaced(name) do
      {:ok, _server_id, original} -> {:ok, original}
      error -> error
    end
  end

  def original_name(_), do: {:error, :invalid_name}

  @doc """
  Returns `true` if the name follows the `mcp:<server_id>:<tool_name>` format.
  """
  @spec mcp_tool_name?(binary()) :: boolean()
  def mcp_tool_name?(name) when is_binary(name) do
    case String.split(name, @namespace_separator, parts: 3) do
      ["mcp", server_id, tool_name] ->
        byte_size(server_id) > 0 and byte_size(tool_name) > 0 and
          not String.contains?(server_id, @namespace_separator) and
          not String.contains?(tool_name, @namespace_separator)

      _ ->
        false
    end
  end

  def mcp_tool_name?(_), do: false

  # -- Private --

  defp parse_namespaced(name) do
    if mcp_tool_name?(name) do
      case String.split(name, @namespace_separator, parts: 3) do
        ["mcp", server_id, original] -> {:ok, server_id, original}
        _ -> {:error, :invalid_namespace_format}
      end
    else
      {:error, :invalid_namespace_format}
    end
  end

  defp reject_colon(value, field) do
    if String.contains?(value, @namespace_separator) do
      {:error, {:colon_in_field, field}}
    else
      :ok
    end
  end

  defp reject_empty(value, field) do
    if byte_size(value) == 0 do
      {:error, {:empty_field, field}}
    else
      :ok
    end
  end

  defp fetch_descriptor_name(descriptor) do
    fetch_descriptor_field(descriptor, "name", nil)
  end

  defp fetch_descriptor_field(descriptor, key, default) do
    Map.get(descriptor, key, Map.get(descriptor, String.to_atom(key), default))
  end

  defp validate_name(nil), do: {:error, :missing_name}
  defp validate_name(name) when is_binary(name) and byte_size(name) > 0, do: {:ok, name}
  defp validate_name(_), do: {:error, :invalid_name}

  defp maybe_with_category(descriptor, opts) do
    explicit =
      fetch_descriptor_field(descriptor, "mcp_category", nil) ||
        Keyword.get(opts, :mcp_category)

    base = %{name: fetch_descriptor_name(descriptor)}

    if explicit, do: Map.put(base, :mcp_category, explicit), else: base
  end

  defp build_annotations(descriptor) do
    descriptor
    |> Map.drop(["name", "description", "inputSchema", "input_schema", "mcp_category"])
    |> Map.drop([:name, :description, :inputSchema, :input_schema, :mcp_category])
  end

  defp wrap_namespaced({:error, _} = err), do: err
  defp wrap_namespaced(name) when is_binary(name), do: {:ok, name}
end
