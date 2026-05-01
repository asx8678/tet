defmodule Tet.Mcp.Tool do
  @moduledoc """
  MCP tool as pure data with namespaced identity.

  Every MCP tool is namespaced under its owning server to prevent collisions
  across servers that expose identically-named tools. The canonical name format
  is `mcp:<server_id>:<original_name>` — e.g. `mcp:fs:read_file`.

  This struct is the single source of truth for what an MCP tool *is*.
  The ToolAdapter handles construction; the ToolRegistry handles bookkeeping.

  ## Invariants

    1. `name` MUST equal `Tet.Mcp.ToolAdapter.namespaced_name(server_id, original_name)`.
    2. Neither `server_id` nor `original_name` may contain `:` (namespace separator).
    3. `name` MUST start with the `mcp:` prefix.
    4. `server_id`, `original_name`, and `description` MUST be non-empty binaries.

  ## Examples

      iex> {:ok, tool} = Tet.Mcp.Tool.new(%{
      ...>   name: "mcp:fs:read_file",
      ...>   server_id: "fs",
      ...>   original_name: "read_file",
      ...>   description: "Read a file"
      ...> })
      iex> tool.name
      "mcp:fs:read_file"
  """

  alias Tet.Mcp.Classification
  alias Tet.Mcp.ToolAdapter

  @enforce_keys [:name, :server_id, :original_name]
  defstruct [
    :name,
    :server_id,
    :original_name,
    description: "",
    input_schema: %{},
    classification: :write,
    annotations: %{}
  ]

  @type classification :: Classification.category()

  @type t :: %__MODULE__{
          name: binary(),
          server_id: binary(),
          original_name: binary(),
          description: binary(),
          input_schema: map(),
          classification: classification(),
          annotations: map()
        }

  @doc """
  Builds a validated MCP tool from a map of attributes (atom or string keys).

  Required fields:
    - `name` — the full namespaced name (must match `mcp:<server_id>:<original_name>`)
    - `server_id` — owning server identifier (non-empty, no colons)
    - `original_name` — tool name as exposed by the server (non-empty, no colons)

  Optional fields:
    - `description` — human-readable description (non-empty binary, default `""`)
    - `input_schema` — JSON Schema map (default `%{}`)
    - `classification` — risk category atom (default from heuristic)
    - `annotations` — extra metadata map (default `%{}`)

  Returns `{:ok, tool}` or `{:error, reason}`.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, name} <- validate_required_binary(attrs, :name),
         {:ok, server_id} <- validate_required_binary(attrs, :server_id),
         {:ok, original_name} <- validate_required_binary(attrs, :original_name),
         :ok <- validate_no_colon(server_id, :server_id),
         :ok <- validate_no_colon(original_name, :original_name),
         :ok <- validate_mcp_prefix(name),
         :ok <- validate_namespaced_name(name, server_id, original_name),
         {:ok, description} <- validate_optional_binary(attrs, :description, ""),
         {:ok, input_schema} <- validate_map(attrs, :input_schema, %{}),
         {:ok, classification} <- validate_classification(attrs),
         {:ok, annotations} <- validate_map(attrs, :annotations, %{}) do
      {:ok,
       %__MODULE__{
         name: name,
         server_id: server_id,
         original_name: original_name,
         description: description,
         input_schema: input_schema,
         classification: classification,
         annotations: annotations
       }}
    end
  end

  def new(_), do: {:error, :invalid_tool_attrs}

  @doc "Builds a tool or raises `ArgumentError`."
  @spec new!(map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, tool} -> tool
      {:error, reason} -> raise ArgumentError, "invalid mcp tool: #{inspect(reason)}"
    end
  end

  @doc """
  Builds a tool from a plain map (string keys for JSON interop).

  This is the inverse of `to_map/1` — suitable for deserialization.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(map) when is_map(map) do
    attrs = %{
      "name" => map["name"],
      "server_id" => map["server_id"],
      "original_name" => map["original_name"],
      "description" => map["description"],
      "input_schema" => map["input_schema"],
      "classification" => parse_classification(map["classification"]),
      "annotations" => map["annotations"]
    }

    new(attrs)
  end

  def from_map(_), do: {:error, :invalid_tool_map}

  @doc """
  Serializes a tool to a plain map (string keys for JSON interop).
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = tool) do
    %{
      "name" => tool.name,
      "server_id" => tool.server_id,
      "original_name" => tool.original_name,
      "description" => tool.description,
      "input_schema" => tool.input_schema,
      "classification" => to_string(tool.classification),
      "annotations" => tool.annotations
    }
  end

  # -- Validators --

  defp validate_required_binary(attrs, key) do
    value = fetch_value(attrs, key)

    case value do
      v when is_binary(v) and byte_size(v) > 0 -> {:ok, v}
      _ -> {:error, {:missing_or_empty, key}}
    end
  end

  defp validate_optional_binary(attrs, key, default) do
    case fetch_value(attrs, key) do
      nil -> {:ok, default}
      v when is_binary(v) -> {:ok, v}
      _ -> {:error, {:invalid_type, key}}
    end
  end

  defp validate_map(attrs, key, default) do
    case fetch_value(attrs, key) do
      nil -> {:ok, default}
      v when is_map(v) -> {:ok, v}
      _ -> {:error, {:invalid_type, key}}
    end
  end

  defp validate_no_colon(value, field) do
    if String.contains?(value, ":") do
      {:error, {:colon_in_field, field}}
    else
      :ok
    end
  end

  defp validate_mcp_prefix(name) do
    if ToolAdapter.mcp_tool_name?(name) do
      :ok
    else
      {:error, :invalid_mcp_prefix}
    end
  end

  defp validate_namespaced_name(name, server_id, original_name) do
    expected = ToolAdapter.namespaced_name(server_id, original_name)

    if name == expected do
      :ok
    else
      {:error, {:name_mismatch, expected: expected, got: name}}
    end
  end

  @valid_classifications Classification.categories()

  defp validate_classification(attrs) do
    case fetch_value(attrs, :classification) do
      nil ->
        {:ok, :write}

      cat when cat in @valid_classifications ->
        {:ok, cat}

      _ ->
        {:error, :invalid_classification}
    end
  end

  defp parse_classification(nil), do: nil
  defp parse_classification(cat) when cat in @valid_classifications, do: cat

  defp parse_classification(str) when is_binary(str) do
    try do
      atom = String.to_existing_atom(str)
      if atom in Classification.categories(), do: atom, else: nil
    rescue
      ArgumentError -> nil
    end
  end

  defp parse_classification(_), do: nil

  defp fetch_value(attrs, key) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
  end
end
