defmodule Tet.Prompt do
  @moduledoc """
  Pure prompt layer contract.

  `Tet.Prompt` turns stable core/runtime data into an ordered, provider-neutral
  prompt. It does not call providers, read files, persist sessions, or know
  about SDK request bodies. Tiny boundary, fewer haunted closets.

  Layer order is deterministic:

  1. system/base prompt;
  2. project rules;
  3. profile/persona layers;
  4. compaction metadata;
  5. attachment metadata;
  6. session messages.

  `debug/1` and `debug_text/1` expose ordered layer ids, hashes, byte counts,
  and redacted metadata without dumping raw prompt content.
  """

  alias Tet.Prompt.{Canonical, Debug, Fields, Layer, Render}

  @version "tet.prompt.v1"
  @layer_kinds [
    :system_base,
    :project_rules,
    :profile,
    :compaction_metadata,
    :attachment_metadata,
    :session_message
  ]

  @top_level_aliases %{
    "attachments" => :attachments,
    "compaction" => :compactions,
    "compactions" => :compactions,
    "messages" => :session_messages,
    "metadata" => :metadata,
    "personas" => :profiles,
    "profile_layers" => :profiles,
    "profiles" => :profiles,
    "project_rules" => :project_rules,
    "prompt_metadata" => :metadata,
    "session_messages" => :session_messages,
    "system" => :system_base,
    "system_base" => :system_base
  }

  @text_layer_aliases %{
    "content" => :content,
    "id" => :id,
    "label" => :label,
    "metadata" => :metadata,
    "name" => :name,
    "path" => :path,
    "persona" => :persona,
    "scope" => :scope,
    "source" => :source
  }

  @compaction_aliases %{
    "id" => :id,
    "metadata" => :metadata,
    "original_message_count" => :original_message_count,
    "retained_message_count" => :retained_message_count,
    "source_message_ids" => :source_message_ids,
    "strategy" => :strategy,
    "summary" => :summary
  }

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

  @typedoc "Accepted prompt build input shape."
  @type build_input :: map() | [{atom() | binary(), term()}]

  @typedoc "Provider-neutral chat message generated from a prompt layer."
  @type prompt_message :: %{
          required(:role) => Tet.Message.role(),
          required(:content) => binary(),
          required(:metadata) => map()
        }

  @type t :: %__MODULE__{
          id: binary(),
          version: binary(),
          hash: binary(),
          metadata: map(),
          layers: [Layer.t()],
          messages: [prompt_message()],
          debug: map()
        }

  @enforce_keys [:id, :version, :hash, :metadata, :layers, :messages, :debug]
  defstruct [:id, :version, :hash, metadata: %{}, layers: [], messages: [], debug: %{}]

  @doc "Returns the prompt contract version string."
  @spec version() :: binary()
  def version, do: @version

  @doc "Builds a deterministic prompt from a map or keyword list."
  @spec build(build_input()) :: {:ok, t()} | {:error, term()}
  def build(attrs) when is_list(attrs) or is_map(attrs) do
    with {:ok, attrs} <- normalize_top_level_attrs(attrs),
         {:ok, prompt_metadata} <- normalize_prompt_metadata(Map.get(attrs, :metadata, %{})),
         {:ok, raw_layers} <- raw_layers(attrs),
         {:ok, layers} <- materialize_layers(raw_layers) do
      messages = messages_from_layers(layers)
      hash = prompt_hash(layers, prompt_metadata)
      id = "prompt-" <> String.slice(hash, 0, 16)

      prompt = %__MODULE__{
        id: id,
        version: @version,
        hash: hash,
        metadata: prompt_metadata,
        layers: layers,
        messages: messages,
        debug: Debug.map(@version, id, hash, prompt_metadata, layers, messages)
      }

      {:ok, prompt}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def build(_attrs), do: {:error, :invalid_prompt_input}

  @doc "Builds a prompt or raises `ArgumentError` with the validation reason."
  @spec build!(build_input()) :: t()
  def build!(attrs) do
    case build(attrs) do
      {:ok, prompt} -> prompt
      {:error, reason} -> raise ArgumentError, "invalid prompt input: #{inspect(reason)}"
    end
  end

  @doc "Returns provider-neutral messages in deterministic layer order."
  @spec to_messages(t()) :: [prompt_message()]
  def to_messages(%__MODULE__{messages: messages}), do: messages

  @doc "Returns role/content maps suitable for provider adapters."
  @spec to_provider_messages(t()) :: [
          %{required(:role) => binary(), required(:content) => binary()}
        ]
  def to_provider_messages(%__MODULE__{messages: messages}) do
    Enum.map(messages, fn message ->
      %{role: Atom.to_string(message.role), content: message.content}
    end)
  end

  @doc "Returns the structured debug map with redacted metadata."
  @spec debug(t()) :: map()
  def debug(%__MODULE__{debug: debug}), do: debug

  @doc "Returns a stable, line-oriented prompt debug snapshot."
  @spec debug_text(t()) :: binary()
  def debug_text(%__MODULE__{} = prompt), do: Debug.text(prompt)

  defp normalize_top_level_attrs(attrs) when is_map(attrs) do
    attrs
    |> Map.to_list()
    |> normalize_top_level_attrs()
  end

  defp normalize_top_level_attrs(attrs) when is_list(attrs) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn
      {key, value}, {:ok, acc} ->
        with {:ok, normalized_key} <- Fields.normalize_alias_key(key, @top_level_aliases),
             :ok <-
               Fields.ensure_absent(
                 acc,
                 normalized_key,
                 {:duplicate_prompt_field, normalized_key}
               ) do
          {:cont, {:ok, Map.put(acc, normalized_key, value)}}
        else
          {:error, {:unknown_key, unknown}} -> {:halt, {:error, {:unknown_prompt_field, unknown}}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _other, _acc ->
        {:halt, {:error, :invalid_prompt_input}}
    end)
  end

  defp normalize_prompt_metadata(metadata) when is_map(metadata),
    do: Canonical.normalize(metadata)

  defp normalize_prompt_metadata(_metadata), do: {:error, :invalid_prompt_metadata}

  defp raw_layers(attrs) do
    with {:ok, system_layer} <- system_layer(Map.get(attrs, :system_base)),
         {:ok, project_layers} <- text_layers(Map.get(attrs, :project_rules), :project_rules),
         {:ok, profile_layers} <- text_layers(Map.get(attrs, :profiles), :profile),
         {:ok, compaction_layers} <- compaction_layers(Map.get(attrs, :compactions)),
         {:ok, attachment_layers} <- attachment_layers(Map.get(attrs, :attachments)),
         {:ok, message_layers} <- session_message_layers(Map.get(attrs, :session_messages)) do
      {:ok,
       [system_layer] ++
         project_layers ++
         profile_layers ++ compaction_layers ++ attachment_layers ++ message_layers}
    end
  end

  defp system_layer(content) when is_binary(content) and content != "" do
    {:ok, raw_layer(:system_base, :system, content, %{source: "system_base"}, nil)}
  end

  defp system_layer(_content), do: {:error, {:missing_prompt_layer, :system_base}}

  defp text_layers(nil, _kind), do: {:ok, []}

  defp text_layers(value, kind) do
    with {:ok, items} <- optional_item_list(value, {:invalid_prompt_layer, kind}) do
      items
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, acc} ->
        case text_layer(item, kind, index) do
          {:ok, layer} -> {:cont, {:ok, [layer | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> Fields.reverse_ok()
    end
  end

  defp text_layer(content, kind, _index) when is_binary(content) and content != "" do
    {:ok, raw_layer(kind, :system, content, %{}, nil)}
  end

  defp text_layer(item, kind, index) when is_map(item) do
    with {:ok, fields} <-
           Fields.normalize(item, @text_layer_aliases, {:invalid_prompt_layer, kind, index}),
         {:ok, content} <-
           Fields.required_non_empty_binary(
             fields,
             :content,
             {:invalid_prompt_layer, kind, index}
           ),
         {:ok, metadata} <-
           Fields.metadata_with_fields(fields, [:source, :scope, :label, :name, :path, :persona]),
         {:ok, id} <- Fields.optional_layer_id(Map.get(fields, :id), index) do
      {:ok, raw_layer(kind, :system, content, metadata, id)}
    end
  end

  defp text_layer(_item, kind, index), do: {:error, {:invalid_prompt_layer, kind, index}}

  defp compaction_layers(nil), do: {:ok, []}

  defp compaction_layers(value) do
    with {:ok, items} <- optional_item_list(value, :invalid_prompt_compaction) do
      items
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, acc} ->
        case compaction_layer(item, index) do
          {:ok, layer} -> {:cont, {:ok, [layer | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> Fields.reverse_ok()
    end
  end

  defp compaction_layer(item, index) when is_map(item) do
    with {:ok, fields} <-
           Fields.normalize(item, @compaction_aliases, {:invalid_prompt_compaction, index}),
         {:ok, summary} <-
           Fields.required_non_empty_binary(fields, :summary, {:invalid_prompt_compaction, index}),
         {:ok, source_message_ids} <-
           source_message_ids(Map.get(fields, :source_message_ids, []), index),
         {:ok, strategy} <-
           Fields.optional_string(
             Map.get(fields, :strategy),
             {:invalid_prompt_compaction, index, :strategy}
           ),
         {:ok, original_count} <-
           Fields.optional_count(
             Map.get(fields, :original_message_count),
             index,
             :original_message_count
           ),
         {:ok, retained_count} <-
           Fields.optional_count(
             Map.get(fields, :retained_message_count),
             index,
             :retained_message_count
           ),
         {:ok, metadata} <-
           compaction_metadata(
             fields,
             source_message_ids,
             strategy,
             original_count,
             retained_count
           ),
         {:ok, id} <- Fields.optional_layer_id(Map.get(fields, :id), index) do
      content =
        Render.compaction(summary, source_message_ids, strategy, original_count, retained_count)

      {:ok, raw_layer(:compaction_metadata, :system, content, metadata, id)}
    end
  end

  defp compaction_layer(_item, index), do: {:error, {:invalid_prompt_compaction, index}}

  defp attachment_layers(nil), do: {:ok, []}
  defp attachment_layers([]), do: {:ok, []}

  defp attachment_layers(value) do
    with {:ok, items} <- optional_item_list(value, :invalid_prompt_attachments),
         {:ok, attachments} <- normalize_attachments(items) do
      content = Render.attachments(attachments)
      metadata = %{attachment_count: length(attachments), attachments: attachments}
      {:ok, [raw_layer(:attachment_metadata, :system, content, metadata, nil)]}
    end
  end

  defp session_message_layers(nil), do: {:ok, []}

  defp session_message_layers(messages) when is_list(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {message, index}, {:ok, acc} ->
      case session_message_layer(message, index) do
        {:ok, layer} -> {:cont, {:ok, [layer | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> Fields.reverse_ok()
  end

  defp session_message_layers(_messages), do: {:error, :invalid_prompt_messages}

  defp session_message_layer(%Tet.Message{} = message, index) do
    message
    |> Tet.Message.to_map()
    |> session_message_layer(index)
  end

  defp session_message_layer(message, index) when is_map(message) do
    case Tet.Message.new(message) do
      {:ok, message} ->
        metadata = %{
          message_id: message.id,
          message_metadata: message.metadata,
          session_id: message.session_id,
          timestamp: message.timestamp
        }

        {:ok,
         raw_layer(
           :session_message,
           message.role,
           message.content,
           metadata,
           "message:" <> message.id
         )}

      {:error, reason} ->
        {:error, {:invalid_prompt_message, index, reason}}
    end
  end

  defp session_message_layer(_message, index), do: {:error, {:invalid_prompt_message, index}}

  defp materialize_layers(raw_layers) do
    raw_layers
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn {raw, index}, {:ok, acc, ids} ->
      case materialize_layer(raw, index) do
        {:ok, layer} ->
          if MapSet.member?(ids, layer.id) do
            {:halt, {:error, {:duplicate_prompt_layer_id, layer.id}}}
          else
            {:cont, {:ok, [layer | acc], MapSet.put(ids, layer.id)}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, layers, _ids} -> {:ok, Enum.reverse(layers)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp materialize_layer(raw, index) do
    with :ok <- validate_layer_kind(raw.kind),
         :ok <- validate_role(raw.role),
         {:ok, metadata} <- Canonical.normalize(raw.metadata),
         {:ok, supplied_id} <- Fields.optional_layer_id(raw.supplied_id, index) do
      hash_source = %{
        content: raw.content,
        index: index,
        kind: raw.kind,
        metadata: metadata,
        role: raw.role,
        supplied_id: supplied_id,
        version: @version
      }

      layer_hash = canonical_hash!(hash_source)
      content_sha256 = Canonical.sha256(raw.content)
      id = supplied_id || generated_layer_id(index, raw.kind, layer_hash)

      {:ok,
       %Layer{
         id: id,
         index: index,
         kind: raw.kind,
         role: raw.role,
         content: raw.content,
         metadata: metadata,
         content_sha256: content_sha256,
         hash: layer_hash
       }}
    end
  end

  defp raw_layer(kind, role, content, metadata, supplied_id) do
    %{kind: kind, role: role, content: content, metadata: metadata, supplied_id: supplied_id}
  end

  defp messages_from_layers(layers) do
    Enum.map(layers, fn layer ->
      %{
        role: layer.role,
        content: layer.content,
        metadata: %{
          prompt_layer_hash: layer.hash,
          prompt_layer_id: layer.id,
          prompt_layer_kind: Atom.to_string(layer.kind)
        }
      }
    end)
  end

  defp prompt_hash(layers, metadata) do
    canonical_hash!(%{
      layers: Enum.map(layers, &%{hash: &1.hash, id: &1.id, index: &1.index}),
      metadata: metadata,
      version: @version
    })
  end

  defp normalize_attachments(items) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, acc} ->
      case normalize_attachment(item, index) do
        {:ok, attachment} -> {:cont, {:ok, [attachment | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> Fields.reverse_ok()
  end

  defp normalize_attachment(item, index) when is_map(item) do
    with :ok <- reject_attachment_payload_fields(item, index),
         {:ok, fields} <-
           Fields.normalize(item, @attachment_aliases, {:invalid_prompt_attachment, index}),
         {:ok, metadata} <- Fields.metadata(Map.get(fields, :metadata, %{})),
         {:ok, byte_size} <- Fields.optional_count(Map.get(fields, :byte_size), index, :byte_size),
         :ok <- ensure_attachment_has_metadata(fields, index),
         {:ok, id} <- attachment_id(fields, index) do
      {:ok,
       %{
         byte_size: byte_size,
         id: id,
         media_type: Fields.optional_binary_value(Map.get(fields, :media_type)),
         metadata: metadata,
         name: Fields.optional_binary_value(Map.get(fields, :name)),
         sha256: Fields.optional_binary_value(Map.get(fields, :sha256)),
         source: Fields.optional_binary_value(Map.get(fields, :source))
       }
       |> drop_nil_values()}
    end
  end

  defp normalize_attachment(_item, index), do: {:error, {:invalid_prompt_attachment, index}}

  defp reject_attachment_payload_fields(item, index) do
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

  defp attachment_id(fields, index) do
    case Map.get(fields, :id) do
      nil ->
        seed =
          fields
          |> Map.take([:byte_size, :media_type, :name, :sha256, :source])
          |> drop_nil_values()
          |> Map.put(:index, index)

        {:ok, "attachment-" <> String.slice(canonical_hash!(seed), 0, 12)}

      id ->
        Fields.optional_layer_id(id, index)
    end
  end

  defp ensure_attachment_has_metadata(fields, index) do
    visible? =
      fields
      |> Map.take([:id, :name, :media_type, :byte_size, :sha256, :source])
      |> Enum.any?(fn {_key, value} -> not is_nil(value) end)

    if visible?, do: :ok, else: {:error, {:invalid_prompt_attachment, index, :empty_metadata}}
  end

  defp compaction_metadata(fields, source_message_ids, strategy, original_count, retained_count) do
    with {:ok, metadata} <- Fields.metadata(Map.get(fields, :metadata, %{})) do
      {:ok,
       metadata
       |> put_present(:source_message_ids, source_message_ids)
       |> put_present(:strategy, strategy)
       |> put_present(:original_message_count, original_count)
       |> put_present(:retained_message_count, retained_count)}
    end
  end

  defp source_message_ids(ids, index) when is_list(ids) do
    if Enum.all?(ids, &(is_binary(&1) and &1 != "")) do
      {:ok, ids}
    else
      {:error, {:invalid_prompt_compaction, index, :source_message_ids}}
    end
  end

  defp source_message_ids(_ids, index),
    do: {:error, {:invalid_prompt_compaction, index, :source_message_ids}}

  defp optional_item_list(nil, _error), do: {:ok, []}
  defp optional_item_list(items, _error) when is_list(items), do: {:ok, items}
  defp optional_item_list(item, _error) when is_binary(item) or is_map(item), do: {:ok, [item]}
  defp optional_item_list(_item, error), do: {:error, error}

  defp generated_layer_id(index, kind, hash) do
    padded_index = index |> Integer.to_string() |> String.pad_leading(3, "0")
    "layer-#{padded_index}-#{kind}-#{String.slice(hash, 0, 12)}"
  end

  defp validate_layer_kind(kind) when kind in @layer_kinds, do: :ok
  defp validate_layer_kind(kind), do: {:error, {:invalid_prompt_layer_kind, kind}}

  defp validate_role(role) do
    if role in Tet.Message.roles(), do: :ok, else: {:error, {:invalid_prompt_role, role}}
  end

  defp canonical_hash!(value) do
    {:ok, normalized} = Canonical.normalize(value)
    Canonical.hash(normalized)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp drop_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end
end
