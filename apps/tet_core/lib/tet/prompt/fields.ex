defmodule Tet.Prompt.Fields do
  @moduledoc false

  @id_pattern ~r/^[A-Za-z0-9._:\/=@+-]+$/

  def normalize(item, aliases, error_prefix) do
    Enum.reduce_while(item, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, field} <- normalize_alias_key(key, aliases),
           :ok <- ensure_absent(acc, field, append_error(error_prefix, {:duplicate_field, field})) do
        {:cont, {:ok, Map.put(acc, field, value)}}
      else
        {:error, {:unknown_key, unknown}} ->
          {:halt, {:error, append_error(error_prefix, {:unknown_field, unknown})}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  def normalize_alias_key(key, aliases) do
    case key_name(key) do
      {:ok, name} ->
        case Map.fetch(aliases, name) do
          {:ok, field} -> {:ok, field}
          :error -> {:error, {:unknown_key, name}}
        end

      :error ->
        {:error, {:unknown_key, inspect(key)}}
    end
  end

  def key_name(key) when is_binary(key), do: {:ok, key}
  def key_name(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  def key_name(_key), do: :error

  def metadata_with_fields(fields, keys) do
    with {:ok, metadata} <- metadata(Map.get(fields, :metadata, %{})) do
      {:ok,
       Enum.reduce(keys, metadata, fn key, acc ->
         if Map.has_key?(fields, key), do: Map.put(acc, key, Map.fetch!(fields, key)), else: acc
       end)}
    end
  end

  def metadata(metadata) when is_map(metadata), do: {:ok, metadata}
  def metadata(_metadata), do: {:error, :invalid_prompt_metadata}

  def required_non_empty_binary(fields, key, error_prefix) do
    case Map.get(fields, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, append_error(error_prefix, {:missing_field, key})}
    end
  end

  def optional_string(nil, _error), do: {:ok, nil}
  def optional_string(value, _error) when is_binary(value) and value != "", do: {:ok, value}
  def optional_string(value, _error) when is_atom(value), do: {:ok, Atom.to_string(value)}
  def optional_string(_value, error), do: {:error, error}

  def optional_count(nil, _index, _field), do: {:ok, nil}

  def optional_count(value, _index, _field) when is_integer(value) and value >= 0,
    do: {:ok, value}

  def optional_count(_value, index, field), do: {:error, {:invalid_prompt_count, index, field}}

  def optional_layer_id(nil, _index), do: {:ok, nil}

  def optional_layer_id(id, index) when is_binary(id) and byte_size(id) <= 200 do
    if String.match?(id, @id_pattern) do
      {:ok, id}
    else
      {:error, {:invalid_prompt_layer_id, index}}
    end
  end

  def optional_layer_id(_id, index), do: {:error, {:invalid_prompt_layer_id, index}}

  def ensure_absent(map, key, error) do
    if Map.has_key?(map, key), do: {:error, error}, else: :ok
  end

  def reverse_ok({:ok, values}), do: {:ok, Enum.reverse(values)}
  def reverse_ok({:error, reason}), do: {:error, reason}

  def append_error(prefix, detail) when is_tuple(prefix),
    do: Tuple.insert_at(prefix, tuple_size(prefix), detail)

  def append_error(prefix, detail), do: {prefix, detail}
end
