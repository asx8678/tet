defmodule Tet.Autosave do
  @moduledoc """
  Pure autosave checkpoint snapshot shared by runtime and store adapters.

  Autosaves are metadata snapshots, not artifact blobs. They persist the chat
  messages needed to restore a session, normalized attachment metadata, and the
  redacted prompt debug artifacts produced by `Tet.Prompt`. Raw attachment
  payload fields are rejected at this boundary too, because one prompt contract
  goblin was already enough.
  """

  alias Tet.Prompt.Canonical

  @payload_keys ~w(body bytes content data)

  @enforce_keys [:checkpoint_id, :session_id, :saved_at]
  defstruct [
    :checkpoint_id,
    :session_id,
    :saved_at,
    messages: [],
    attachments: [],
    prompt_metadata: %{},
    prompt_debug: %{},
    prompt_debug_text: "",
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          checkpoint_id: binary(),
          session_id: binary(),
          saved_at: binary(),
          messages: [Tet.Message.t()],
          attachments: [map()],
          prompt_metadata: map(),
          prompt_debug: map(),
          prompt_debug_text: binary(),
          metadata: map()
        }

  @doc "Builds a validated autosave checkpoint from atom or string keyed attrs."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, checkpoint_id} <- fetch_binary(attrs, :checkpoint_id),
         {:ok, session_id} <- fetch_binary(attrs, :session_id),
         {:ok, saved_at} <- fetch_binary(attrs, :saved_at),
         {:ok, messages} <- fetch_messages(attrs),
         {:ok, attachments} <- fetch_attachments(attrs),
         {:ok, prompt_metadata} <- fetch_normalized_map(attrs, :prompt_metadata),
         {:ok, prompt_debug} <- fetch_normalized_map(attrs, :prompt_debug),
         {:ok, prompt_debug_text} <- fetch_optional_binary(attrs, :prompt_debug_text, ""),
         {:ok, metadata} <- fetch_normalized_map(attrs, :metadata) do
      {:ok,
       %__MODULE__{
         checkpoint_id: checkpoint_id,
         session_id: session_id,
         saved_at: saved_at,
         messages: messages,
         attachments: attachments,
         prompt_metadata: prompt_metadata,
         prompt_debug: prompt_debug,
         prompt_debug_text: prompt_debug_text,
         metadata: metadata
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_autosave}

  @doc "Converts a decoded map back to a validated autosave checkpoint."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  @doc "Builds an autosave checkpoint from a prompt and its persisted messages."
  @spec from_prompt(binary(), [Tet.Message.t()], Tet.Prompt.t(), map() | keyword()) ::
          {:ok, t()} | {:error, term()}
  def from_prompt(session_id, messages, %Tet.Prompt{} = prompt, attrs \\ %{})
      when is_binary(session_id) and is_list(messages) and (is_map(attrs) or is_list(attrs)) do
    attrs = attrs_map(attrs)
    saved_at = fetch_value(attrs, :saved_at)

    checkpoint_id =
      fetch_value(attrs, :checkpoint_id) ||
        generated_checkpoint_id(session_id, saved_at, messages, prompt)

    new(%{
      checkpoint_id: checkpoint_id,
      session_id: session_id,
      saved_at: saved_at,
      messages: messages,
      attachments: Tet.Prompt.attachment_metadata(prompt),
      prompt_metadata: prompt.metadata,
      prompt_debug: Tet.Prompt.debug(prompt),
      prompt_debug_text: Tet.Prompt.debug_text(prompt),
      metadata: fetch_value(attrs, :metadata, %{})
    })
  end

  @doc "Converts the checkpoint to a JSON-friendly map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = autosave) do
    %{
      checkpoint_id: autosave.checkpoint_id,
      session_id: autosave.session_id,
      saved_at: autosave.saved_at,
      messages: Enum.map(autosave.messages, &Tet.Message.to_map/1),
      attachments: autosave.attachments,
      prompt_metadata: autosave.prompt_metadata,
      prompt_debug: autosave.prompt_debug,
      prompt_debug_text: autosave.prompt_debug_text,
      metadata: autosave.metadata
    }
  end

  defp fetch_messages(attrs) do
    case fetch_value(attrs, :messages, []) do
      messages when is_list(messages) -> normalize_messages(messages)
      _messages -> {:error, {:invalid_autosave_field, :messages}}
    end
  end

  defp normalize_messages(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {message, index}, {:ok, acc} ->
      case normalize_message(message, index) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_message(%Tet.Message{} = message, _index), do: {:ok, message}

  defp normalize_message(message, index) when is_map(message) do
    case Tet.Message.from_map(message) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, reason} -> {:error, {:invalid_autosave_message, index, reason}}
    end
  end

  defp normalize_message(_message, index), do: {:error, {:invalid_autosave_message, index}}

  defp fetch_attachments(attrs) do
    case fetch_value(attrs, :attachments, []) do
      attachments when is_list(attachments) -> normalize_attachments(attachments)
      _attachments -> {:error, {:invalid_autosave_field, :attachments}}
    end
  end

  defp normalize_attachments(attachments) do
    attachments
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {attachment, index}, {:ok, acc} ->
      case normalize_attachment(attachment, index) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_attachment(attachment, index) when is_map(attachment) do
    with :ok <- reject_payload_fields(attachment, index),
         {:ok, normalized} <- Canonical.normalize(attachment) do
      {:ok, normalized}
    else
      {:error, {:invalid_prompt_metadata_key, _path}} = error -> error
      {:error, {:invalid_prompt_metadata_value, _path}} = error -> error
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_attachment(_attachment, index),
    do: {:error, {:invalid_autosave_attachment, index}}

  defp reject_payload_fields(attachment, index) do
    has_payload? =
      Enum.any?(attachment, fn {key, _value} ->
        case key_name(key) do
          {:ok, name} -> name in @payload_keys
          :error -> false
        end
      end)

    if has_payload? do
      {:error, {:invalid_autosave_attachment, index, :content_not_allowed}}
    else
      :ok
    end
  end

  defp fetch_normalized_map(attrs, key) do
    case fetch_value(attrs, key, %{}) do
      value when is_map(value) -> Canonical.normalize(value)
      _value -> {:error, {:invalid_autosave_field, key}}
    end
  end

  defp fetch_binary(attrs, key) do
    case fetch_value(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:invalid_autosave_field, key}}
    end
  end

  defp fetch_optional_binary(attrs, key, default) do
    case fetch_value(attrs, key, default) do
      value when is_binary(value) -> {:ok, value}
      _value -> {:error, {:invalid_autosave_field, key}}
    end
  end

  defp generated_checkpoint_id(_session_id, saved_at, _messages, _prompt)
       when not is_binary(saved_at) or saved_at == "" do
    nil
  end

  defp generated_checkpoint_id(session_id, saved_at, messages, prompt) do
    source = %{
      message_ids: Enum.map(messages, &message_id/1),
      prompt_hash: prompt.hash,
      saved_at: saved_at,
      session_id: session_id
    }

    {:ok, normalized} = Canonical.normalize(source)
    "autosave-" <> String.slice(Canonical.hash(normalized), 0, 16)
  end

  defp message_id(%Tet.Message{id: id}), do: id
  defp message_id(message) when is_map(message), do: fetch_value(message, :id)
  defp message_id(_message), do: nil

  defp attrs_map(attrs) when is_map(attrs), do: attrs
  defp attrs_map(attrs) when is_list(attrs), do: Map.new(attrs)

  defp fetch_value(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp key_name(key) when is_binary(key), do: {:ok, key}
  defp key_name(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp key_name(_key), do: :error
end
