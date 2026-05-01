defmodule Tet.Patch.Operation do
  @moduledoc """
  A single file operation within a patch proposal — BD-0028.

  ## Fields

    - `kind` — one of `:create`, `:modify`, `:delete`
    - `file_path` — workspace-relative file path
    - `content` — full new content for `:create` or `:modify` (optional;
      for `:modify`, either `content` or `replacements` must be present)
    - `replacements` — list of `%{old_str: binary(), new_str: binary()}`
      maps for targeted in-file text replacements on `:modify` operations
    - `old_str` / `new_str` — convenience singleton replacement fields
      (mutually exclusive with `replacements`)
    - `expected_hash` — optional sha256 hex string of the file content
      before modification (for `:modify` and `:delete` operations)

  ## Validation rules

    - `:create` requires `content` and must not have `old_str`/`replacements`
    - `:modify` requires either `content` or `replacements`/`old_str`
    - `:delete` must not have `content`, `replacements`, or `old_str`
    - All paths must be non-empty, relative, and free of traversal components

  This struct is pure data. No I/O, no GenServer, no filesystem.
  """

  @kinds [:create, :modify, :delete]

  @enforce_keys [:kind, :file_path]
  defstruct [
    :kind,
    :file_path,
    :content,
    :replacements,
    :old_str,
    :new_str,
    :expected_hash
  ]

  @type kind :: :create | :modify | :delete
  @type replacement :: %{required(:old_str) => String.t(), required(:new_str) => String.t()}

  @type t :: %__MODULE__{
          kind: kind(),
          file_path: String.t(),
          content: String.t() | nil,
          replacements: [replacement()] | nil,
          old_str: String.t() | nil,
          new_str: String.t() | nil,
          expected_hash: String.t() | nil
        }

  @doc "Returns the valid operation kinds."
  @spec kinds() :: [:create | :modify | :delete]
  def kinds, do: @kinds

  @doc """
  Builds a validated operation struct from attributes.

  Returns `{:ok, %__MODULE__{}}` or `{:error, reason}`.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    normalized = normalize_keys(attrs)

    with {:ok, kind} <- fetch_kind(normalized),
         {:ok, file_path} <- fetch_path(normalized),
         :ok <- validate_operation(kind, normalized) do
      operation = %__MODULE__{
        kind: kind,
        file_path: file_path,
        content: Map.get(normalized, :content),
        replacements: Map.get(normalized, :replacements),
        old_str: Map.get(normalized, :old_str),
        new_str: Map.get(normalized, :new_str),
        expected_hash: Map.get(normalized, :expected_hash)
      }

      {:ok, operation}
    end
  end

  @doc "Builds an operation or raises `ArgumentError`."
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    case new(attrs) do
      {:ok, operation} -> operation
      {:error, reason} -> raise ArgumentError, "invalid patch operation: #{inspect(reason)}"
    end
  end

  @doc """
  Converts an operation to a JSON-friendly map with string keys.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = op) do
    %{
      "kind" => Atom.to_string(op.kind),
      "file_path" => op.file_path,
      "content" => op.content,
      "replacements" => op.replacements,
      "old_str" => op.old_str,
      "new_str" => op.new_str,
      "expected_hash" => op.expected_hash
    }
    |> Enum.filter(fn {_k, v} -> not is_nil(v) end)
    |> Map.new()
  end

  # -- Private helpers --

  defp normalize_keys(attrs) do
    Map.new(attrs, fn {key, value} ->
      {normalize_key(key), value}
    end)
  end

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    case key do
      "kind" -> :kind
      "file_path" -> :file_path
      "file-path" -> :file_path
      "content" -> :content
      "replacements" -> :replacements
      "old_str" -> :old_str
      "old-str" -> :old_str
      "new_str" -> :new_str
      "new-str" -> :new_str
      "expected_hash" -> :expected_hash
      "expected-hash" -> :expected_hash
      _ -> String.to_atom(key)
    end
  end

  defp normalize_key(key), do: key

  defp fetch_kind(attrs) do
    value = Map.get(attrs, :kind)

    cond do
      is_atom(value) and value in @kinds -> {:ok, value}
      is_binary(value) -> kind_from_string(value)
      true -> {:error, {:invalid_operation_kind, value}}
    end
  end

  defp kind_from_string("create"), do: {:ok, :create}
  defp kind_from_string("modify"), do: {:ok, :modify}
  defp kind_from_string("delete"), do: {:ok, :delete}
  defp kind_from_string(other), do: {:error, {:invalid_operation_kind, other}}

  defp fetch_path(attrs) do
    value = Map.get(attrs, :file_path)

    cond do
      not is_binary(value) or value == "" ->
        {:error, {:invalid_operation_path, :empty_or_not_string}}

      String.starts_with?(value, "/") ->
        {:error, {:invalid_operation_path, :absolute}}

      String.contains?(value, "..") ->
        {:error, {:invalid_operation_path, :traversal}}

      String.contains?(value, <<0>>) ->
        {:error, {:invalid_operation_path, :null_byte}}

      true ->
        {:ok, value}
    end
  end

  defp validate_operation(:create, attrs) do
    content = Map.get(attrs, :content)
    replacements = Map.get(attrs, :replacements)
    old_str = Map.get(attrs, :old_str)

    cond do
      not is_binary(content) or content == "" ->
        {:error, {:invalid_operation, :create_requires_content}}

      not is_nil(replacements) ->
        {:error, {:invalid_operation, :create_with_replacements}}

      not is_nil(old_str) ->
        {:error, {:invalid_operation, :create_with_old_str}}

      true ->
        :ok
    end
  end

  defp validate_operation(:modify, attrs) do
    content = Map.get(attrs, :content)
    replacements = Map.get(attrs, :replacements)
    old_str = Map.get(attrs, :old_str)

    has_content = is_binary(content) and content != ""
    has_replacements = is_list(replacements) and replacements != []
    has_old_str = is_binary(old_str) and old_str != ""

    cond do
      not has_content and not has_replacements and not has_old_str ->
        {:error, {:invalid_operation, :modify_requires_content_or_replacements}}

      has_replacements and has_old_str ->
        {:error, {:invalid_operation, :modify_with_both_replacements_and_old_str}}

      has_replacements and not valid_replacements?(replacements) ->
        {:error, {:invalid_operation, :invalid_replacements}}

      true ->
        :ok
    end
  end

  defp validate_operation(:delete, attrs) do
    content = Map.get(attrs, :content)
    replacements = Map.get(attrs, :replacements)
    old_str = Map.get(attrs, :old_str)

    cond do
      not is_nil(content) -> {:error, {:invalid_operation, :delete_with_content}}
      not is_nil(replacements) -> {:error, {:invalid_operation, :delete_with_replacements}}
      not is_nil(old_str) -> {:error, {:invalid_operation, :delete_with_old_str}}
      true -> :ok
    end
  end

  defp validate_operation(_kind, _attrs) do
    {:error, {:invalid_operation, :unknown_kind}}
  end

  defp valid_replacements?(replacements) when is_list(replacements) do
    Enum.all?(replacements, fn r ->
      is_map(r) and is_binary(Map.get(r, :old_str, Map.get(r, "old_str", ""))) and
        Map.get(r, :old_str, Map.get(r, "old_str", "")) != ""
    end)
  end

  defp valid_replacements?(_), do: false
end
