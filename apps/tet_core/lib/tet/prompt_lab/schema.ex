defmodule Tet.PromptLab.Schema do
  @moduledoc false

  alias Tet.Prompt.Canonical

  @id_pattern ~r/^[A-Za-z0-9._:\/=@+-]+$/

  def attrs_map(attrs) when is_map(attrs), do: attrs
  def attrs_map(attrs) when is_list(attrs), do: Map.new(attrs)

  def fetch_value(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  def required_binary(attrs, key, error) do
    case fetch_value(attrs, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, error}, else: {:ok, value}

      value when is_atom(value) ->
        {:ok, Atom.to_string(value)}

      _value ->
        {:error, error}
    end
  end

  def optional_binary(attrs, key, default, error) do
    case fetch_value(attrs, key, default) do
      value when is_binary(value) -> {:ok, value}
      value when is_atom(value) -> {:ok, Atom.to_string(value)}
      _value -> {:error, error}
    end
  end

  def optional_string_list(attrs, key, default, error) do
    attrs
    |> fetch_value(key, default)
    |> normalize_string_list(error)
  end

  def required_string_list(attrs, key, error) do
    with {:ok, values} <- optional_string_list(attrs, key, [], error) do
      if values == [], do: {:error, error}, else: {:ok, values}
    end
  end

  def normalize_string_list(nil, _error), do: {:ok, []}

  def normalize_string_list(value, error) when is_binary(value) or is_atom(value) do
    normalize_string_list([value], error)
  end

  def normalize_string_list(values, error) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn
      value, {:ok, acc} when is_binary(value) ->
        value = String.trim(value)

        if value == "" do
          {:halt, {:error, error}}
        else
          {:cont, {:ok, [value | acc]}}
        end

      value, {:ok, acc} when is_atom(value) ->
        {:cont, {:ok, [Atom.to_string(value) | acc]}}

      _value, _acc ->
        {:halt, {:error, error}}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  def normalize_string_list(_value, error), do: {:error, error}

  def metadata(attrs, key, error) do
    attrs
    |> fetch_value(key, %{})
    |> normalize_metadata(error)
  end

  def normalize_metadata(value, error) when is_map(value) do
    case Canonical.normalize(value) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, reason} -> {:error, {error, reason}}
    end
  end

  def normalize_metadata(_value, error), do: {:error, error}

  def validate_id(id, error) when is_binary(id) and byte_size(id) <= 200 do
    if String.match?(id, @id_pattern), do: {:ok, id}, else: {:error, error}
  end

  def validate_id(id, error) when is_atom(id), do: validate_id(Atom.to_string(id), error)
  def validate_id(_id, error), do: {:error, error}

  def generated_id(prefix, source) when is_binary(prefix) do
    {:ok, normalized} = Canonical.normalize(source)
    prefix <> String.slice(Canonical.hash(normalized), 0, 16)
  end

  def hash_text(value) when is_binary(value), do: Canonical.sha256(value)
end
