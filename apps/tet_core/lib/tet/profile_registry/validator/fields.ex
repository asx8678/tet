defmodule Tet.ProfileRegistry.Validator.Fields do
  @moduledoc false

  alias Tet.ProfileRegistry.Error

  def required_non_empty_map_field(raw, field, path, errors) do
    case required_map_field(raw, field, path, errors) do
      {nil, errors} ->
        {nil, errors}

      {value, errors} when map_size(value) == 0 ->
        message = "#{path_label(path)} must declare at least one entry"
        {value, [error(path, :invalid_value, message, %{}) | errors]}

      {value, errors} ->
        {value, errors}
    end
  end

  def required_map_field(raw, field, path, errors) do
    case fetch_field(raw, field) do
      :error -> {nil, [required_error(path) | errors]}
      {:ok, value} when is_map(value) -> {value, errors}
      {:ok, value} -> {nil, [type_error(path, "object", value) | errors]}
    end
  end

  def optional_map_field(raw, field, default, path, errors) do
    case fetch_field(raw, field) do
      :error -> {default, errors}
      {:ok, value} when is_map(value) -> {value, errors}
      {:ok, value} -> {default, [type_error(path, "object", value) | errors]}
    end
  end

  def required_string_field(raw, field, path, errors) do
    case fetch_field(raw, field) do
      :error -> {nil, [required_error(path) | errors]}
      {:ok, value} -> string_field_value(value, path, errors)
    end
  end

  def optional_string_field(raw, field, default, path, errors) do
    case fetch_field(raw, field) do
      :error -> {default, errors}
      {:ok, value} -> string_field_value(value, path, errors, default)
    end
  end

  def required_positive_integer_field(raw, field, path, errors) do
    case fetch_field(raw, field) do
      :error -> {nil, [required_error(path) | errors]}
      {:ok, value} when is_integer(value) and value > 0 -> {value, errors}
      {:ok, value} -> {value, [type_error(path, "positive integer", value) | errors]}
    end
  end

  def optional_positive_integer_field(raw, field, path, errors) do
    case fetch_field(raw, field) do
      :error -> {nil, errors}
      {:ok, value} when is_integer(value) and value > 0 -> {value, errors}
      {:ok, value} -> {nil, [type_error(path, "positive integer", value) | errors]}
    end
  end

  def optional_boolean_field(raw, field, default, path, errors) do
    case fetch_field(raw, field) do
      :error -> {default, errors}
      {:ok, value} when is_boolean(value) -> {value, errors}
      {:ok, value} -> {default, [type_error(path, "boolean", value) | errors]}
    end
  end

  def fetch_field(raw, field) do
    atom_field = String.to_atom(field)

    cond do
      Map.has_key?(raw, field) -> {:ok, Map.fetch!(raw, field)}
      Map.has_key?(raw, atom_field) -> {:ok, Map.fetch!(raw, atom_field)}
      true -> :error
    end
  end

  def id_from_key(key) when is_binary(key), do: normalize_id(key)
  def id_from_key(key) when is_atom(key), do: key |> Atom.to_string() |> normalize_id()
  def id_from_key(_key), do: {:error, "profile ids must be strings or atoms"}

  def string_value(value) when is_binary(value), do: normalize_id(value)
  def string_value(value) when is_boolean(value) or is_nil(value), do: :error
  def string_value(value) when is_atom(value), do: value |> Atom.to_string() |> normalize_id()
  def string_value(_value), do: :error

  def put_optional(map, _key, nil), do: map
  def put_optional(map, key, value), do: Map.put(map, key, value)

  def type_error(path, expected, actual, message \\ nil) do
    error(path, :invalid_type, message || "#{path_label(path)} must be #{expected}", %{
      expected: expected,
      actual: actual_type(actual)
    })
  end

  def error(path, code, message, details) do
    %Error{path: path, code: code, message: message, details: details}
  end

  def path_label([]), do: "profile registry"

  def path_label(path) do
    Enum.map_join(path, ".", &to_string/1)
  end

  defp string_field_value(value, path, errors, fallback \\ nil) do
    case string_value(value) do
      {:ok, string} -> {string, errors}
      :error -> {fallback, [type_error(path, "non-empty string", value) | errors]}
    end
  end

  defp normalize_id(value) do
    case String.trim(value) do
      "" -> {:error, "profile ids must not be blank"}
      id -> {:ok, id}
    end
  end

  defp required_error(path) do
    error(path, :required, "#{path_label(path)} is required", %{})
  end

  defp actual_type(value) when is_map(value), do: "object"
  defp actual_type(value) when is_list(value), do: "array"
  defp actual_type(value) when is_binary(value), do: "string"
  defp actual_type(value) when is_boolean(value), do: "boolean"
  defp actual_type(value) when is_nil(value), do: "null"
  defp actual_type(value) when is_integer(value), do: "integer"
  defp actual_type(value) when is_float(value), do: "float"
  defp actual_type(value) when is_atom(value), do: "atom"
  defp actual_type(_value), do: "term"
end
