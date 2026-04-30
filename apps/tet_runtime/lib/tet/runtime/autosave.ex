defmodule Tet.Runtime.Autosave do
  @moduledoc """
  Runtime autosave/restore orchestration.

  The runtime fetches persisted messages, builds the pure `Tet.Prompt` snapshot,
  and asks the configured store adapter to persist a checkpoint. Restore returns
  the latest checkpoint data; it does not replay messages into the primary log,
  because duplicate history is not a feature, it is a raccoon in a trench coat.
  """

  alias Tet.Runtime.{Ids, StoreConfig}

  @message_fields ~w(messages session_messages)

  @doc "Autosaves one persisted session with prompt metadata/debug artifacts."
  def save(session_id, prompt_attrs, opts \\ []) when is_binary(session_id) and is_list(opts) do
    session_id = String.trim(session_id)

    with :ok <- validate_session_id(session_id),
         {:ok, adapter, store_opts} <-
           StoreConfig.resolve(opts, [:list_messages, :save_autosave]),
         {:ok, messages} <- adapter.list_messages(session_id, store_opts),
         :ok <- ensure_messages(messages),
         {:ok, prompt} <- build_prompt(prompt_attrs, messages),
         {:ok, autosave} <- build_autosave(session_id, messages, prompt, opts),
         {:ok, autosave} <- adapter.save_autosave(autosave, store_opts) do
      {:ok, autosave}
    end
  end

  @doc "Loads the latest autosave checkpoint for a session."
  def restore(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    session_id = String.trim(session_id)

    with :ok <- validate_session_id(session_id),
         {:ok, adapter, store_opts} <- StoreConfig.resolve(opts, [:load_autosave]) do
      adapter.load_autosave(session_id, store_opts)
    end
  end

  @doc "Lists persisted autosave checkpoints, newest first."
  def list(opts \\ []) when is_list(opts) do
    with {:ok, adapter, store_opts} <- StoreConfig.resolve(opts, [:list_autosaves]) do
      adapter.list_autosaves(store_opts)
    end
  end

  defp build_prompt(attrs, messages) when is_map(attrs) or is_list(attrs) do
    attrs
    |> put_session_messages(messages)
    |> Tet.Prompt.build()
  end

  defp build_prompt(_attrs, _messages), do: {:error, :invalid_prompt_input}

  defp build_autosave(session_id, messages, prompt, opts) do
    Tet.Autosave.from_prompt(session_id, messages, prompt, %{
      checkpoint_id: Keyword.get(opts, :checkpoint_id),
      metadata: Keyword.get(opts, :autosave_metadata, %{}),
      saved_at: Keyword.get(opts, :saved_at, Ids.timestamp())
    })
  end

  defp put_session_messages(attrs, messages) when is_map(attrs) do
    attrs
    |> Enum.reject(fn {key, _value} -> message_field?(key) end)
    |> Map.new()
    |> Map.put(:messages, messages)
  end

  defp put_session_messages(attrs, messages) when is_list(attrs) do
    attrs
    |> Enum.reject(fn
      {key, _value} -> message_field?(key)
      _other -> false
    end)
    |> Kernel.++(messages: messages)
  end

  defp message_field?(key) when is_binary(key), do: key in @message_fields
  defp message_field?(key) when is_atom(key), do: Atom.to_string(key) in @message_fields
  defp message_field?(_key), do: false

  defp validate_session_id(""), do: {:error, :empty_session_id}
  defp validate_session_id(_session_id), do: :ok

  defp ensure_messages([]), do: {:error, :session_not_found}
  defp ensure_messages(_messages), do: :ok
end
