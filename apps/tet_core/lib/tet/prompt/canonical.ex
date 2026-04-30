defmodule Tet.Prompt.Canonical do
  @moduledoc false

  @doc "Normalizes JSON-like metadata into deterministic string-keyed maps."
  @spec normalize(term()) :: {:ok, term()} | {:error, term()}
  def normalize(value), do: normalize(value, [])

  defp normalize(nil, _path), do: {:ok, nil}
  defp normalize(value, _path) when is_boolean(value), do: {:ok, value}
  defp normalize(value, _path) when is_binary(value), do: {:ok, value}
  defp normalize(value, _path) when is_integer(value), do: {:ok, value}

  defp normalize(value, path) when is_float(value) do
    if finite_float?(value) do
      {:ok, value}
    else
      {:error, {:invalid_prompt_metadata_value, Enum.reverse(path)}}
    end
  end

  defp normalize(value, _path) when is_atom(value), do: {:ok, Atom.to_string(value)}

  defp normalize(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, acc} ->
      case normalize(item, [index | path]) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize(value, path) when is_map(value) do
    value
    |> Enum.reduce_while({:ok, %{}, MapSet.new()}, fn {key, item}, {:ok, acc, seen} ->
      with {:ok, normalized_key} <- normalize_key(key, path),
           :ok <- ensure_unique_key(normalized_key, seen, path),
           {:ok, normalized_item} <- normalize(item, [normalized_key | path]) do
        {:cont,
         {:ok, Map.put(acc, normalized_key, normalized_item), MapSet.put(seen, normalized_key)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized, _seen} -> {:ok, normalized}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize(_value, path), do: {:error, {:invalid_prompt_metadata_value, Enum.reverse(path)}}

  @doc "Returns a deterministic JSON-like encoding for a normalized value."
  @spec encode(term()) :: binary()
  def encode(value) when is_map(value) do
    inner =
      value
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map(fn key -> encode(key) <> ":" <> encode(Map.fetch!(value, key)) end)
      |> Enum.join(",")

    "{" <> inner <> "}"
  end

  def encode(value) when is_list(value) do
    "[" <> Enum.map_join(value, ",", &encode/1) <> "]"
  end

  def encode(value) when is_binary(value) do
    value
    |> :json.encode()
    |> IO.iodata_to_binary()
  end

  def encode(nil), do: "null"
  def encode(true), do: "true"
  def encode(false), do: "false"
  def encode(value) when is_integer(value), do: Integer.to_string(value)
  def encode(value) when is_float(value), do: Float.to_string(value)
  def encode(value) when is_atom(value), do: value |> Atom.to_string() |> encode()

  @doc "Hashes a normalized value with canonical encoding."
  @spec hash(term()) :: binary()
  def hash(value), do: value |> encode() |> sha256()

  @doc "Hashes raw prompt content."
  @spec sha256(binary()) :: binary()
  def sha256(content) when is_binary(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end

  defp normalize_key(key, _path) when is_binary(key) and key != "", do: {:ok, key}
  defp normalize_key(key, _path) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_key(_key, path), do: {:error, {:invalid_prompt_metadata_key, Enum.reverse(path)}}

  defp ensure_unique_key(key, seen, path) do
    if MapSet.member?(seen, key) do
      {:error, {:duplicate_prompt_metadata_key, Enum.reverse([key | path])}}
    else
      :ok
    end
  end

  defp finite_float?(value) do
    value - value == 0.0
  rescue
    ArithmeticError -> false
  end
end
