defmodule Tet.Prompt.Attachments do
  @moduledoc false

  alias Tet.Prompt.{Canonical, Fields}

  @attachment_aliases %{
    "byte_size" => :byte_size,
    "id" => :id,
    "media_type" => :media_type,
    "metadata" => :metadata,
    "name" => :name,
    "sha256" => :sha256,
    "size" => :byte_size,
    "source" => :source
  }

  @string_fields [:media_type, :name, :sha256, :source]

  def normalize(items) when is_list(items) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, acc} ->
      case normalize_one(item, index) do
        {:ok, attachment} -> {:cont, {:ok, [attachment | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> Fields.reverse_ok()
  end

  defp normalize_one(item, index) when is_map(item) do
    with :ok <- reject_payload_fields(item, index),
         {:ok, fields} <-
           Fields.normalize(item, @attachment_aliases, {:invalid_prompt_attachment, index}),
         {:ok, metadata} <- Fields.metadata(Map.get(fields, :metadata, %{})),
         {:ok, byte_size} <- Fields.optional_count(Map.get(fields, :byte_size), index, :byte_size),
         {:ok, strings} <- optional_strings(fields, index),
         normalized_fields = normalized_fields(fields, byte_size, strings),
         :ok <- ensure_has_visible_metadata(normalized_fields, index),
         {:ok, id} <- attachment_id(normalized_fields, index) do
      {:ok, attachment(id, byte_size, metadata, strings)}
    end
  end

  defp normalize_one(_item, index), do: {:error, {:invalid_prompt_attachment, index}}

  defp reject_payload_fields(item, index) do
    payload_keys = MapSet.new(["body", "bytes", "content", "data"])

    has_payload? =
      Enum.any?(item, fn {key, _value} ->
        case Fields.key_name(key) do
          {:ok, name} -> MapSet.member?(payload_keys, name)
          :error -> false
        end
      end)

    if has_payload? do
      {:error, {:invalid_prompt_attachment, index, :content_not_allowed}}
    else
      :ok
    end
  end

  defp optional_strings(fields, index) do
    Enum.reduce_while(@string_fields, {:ok, %{}}, fn field, {:ok, acc} ->
      case optional_string(Map.get(fields, field), index, field) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, Map.put(acc, field, value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp optional_string(nil, _index, _field), do: {:ok, nil}
  defp optional_string("", _index, _field), do: {:ok, nil}
  defp optional_string(value, _index, _field) when is_binary(value), do: {:ok, value}

  defp optional_string(_value, index, field),
    do: {:error, {:invalid_prompt_attachment, index, field}}

  defp normalized_fields(fields, byte_size, strings) do
    fields
    |> Map.take([:id])
    |> put_present(:byte_size, byte_size)
    |> Map.merge(strings)
  end

  defp ensure_has_visible_metadata(fields, index) do
    visible? =
      fields
      |> Map.take([:id, :name, :media_type, :byte_size, :sha256, :source])
      |> Enum.any?(fn {_key, value} -> not is_nil(value) end)

    if visible?, do: :ok, else: {:error, {:invalid_prompt_attachment, index, :empty_metadata}}
  end

  defp attachment_id(fields, index) do
    case Map.get(fields, :id) do
      nil ->
        seed =
          fields
          |> Map.take([:byte_size, :media_type, :name, :sha256, :source])
          |> Map.put(:index, index)

        {:ok, "attachment-" <> String.slice(canonical_hash!(seed), 0, 12)}

      id ->
        Fields.optional_layer_id(id, index)
    end
  end

  defp attachment(id, byte_size, metadata, strings) do
    %{id: id, metadata: metadata}
    |> put_present(:byte_size, byte_size)
    |> Map.merge(strings)
  end

  defp canonical_hash!(value) do
    {:ok, normalized} = Canonical.normalize(value)
    Canonical.hash(normalized)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
