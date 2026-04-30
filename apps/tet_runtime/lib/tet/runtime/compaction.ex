defmodule Tet.Runtime.Compaction do
  @moduledoc """
  Runtime boundary for compacting persisted session context.

  Store adapters provide durable messages; the pure `Tet.Compaction` contract
  decides the safe split. Runtime does not persist synthetic summary messages by
  default, because compacted context is a provider/prompt view over the durable
  session log, not a replacement for it. Domain truth stays boring and durable.
  """

  alias Tet.Runtime.StoreConfig

  @compaction_option_keys [
    :force,
    :id,
    :max_messages,
    :min_compacted_count,
    :protected_recent_count,
    :recent_count,
    :recent_messages,
    :strategy,
    :summary
  ]

  @doc "Fetches persisted session messages and returns a compacted-context result."
  @spec compact_context(binary(), keyword()) :: {:ok, Tet.Compaction.t()} | {:error, term()}
  def compact_context(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    session_id = String.trim(session_id)

    with :ok <- validate_session_id(session_id),
         {:ok, adapter, store_opts} <- StoreConfig.resolve(opts, [:list_messages]),
         {:ok, messages} <- adapter.list_messages(session_id, store_opts),
         :ok <- ensure_messages(messages),
         {:ok, compaction_opts} <- compaction_opts(opts) do
      Tet.Compaction.compact(messages, compaction_opts)
    end
  end

  @doc "Extracts compaction-only options from mixed runtime/store options."
  @spec compaction_opts(keyword()) :: {:ok, keyword() | map()} | {:error, term()}
  def compaction_opts(opts) when is_list(opts) do
    case Keyword.get(opts, :compaction) do
      nil -> {:ok, Keyword.take(opts, @compaction_option_keys)}
      false -> {:ok, Keyword.take(opts, @compaction_option_keys)}
      true -> {:ok, Keyword.take(opts, @compaction_option_keys)}
      nested when is_list(nested) or is_map(nested) -> {:ok, merge_compaction_opts(opts, nested)}
      _other -> {:error, {:invalid_compaction_option, :compaction}}
    end
  end

  defp merge_compaction_opts(opts, nested) when is_map(nested) do
    opts
    |> Keyword.take(@compaction_option_keys)
    |> Map.new()
    |> Map.merge(nested)
  end

  defp merge_compaction_opts(opts, nested) when is_list(nested) do
    opts
    |> Keyword.take(@compaction_option_keys)
    |> Keyword.merge(nested)
  end

  defp validate_session_id(""), do: {:error, :empty_session_id}
  defp validate_session_id(_session_id), do: :ok

  defp ensure_messages([]), do: {:error, :session_not_found}
  defp ensure_messages(_messages), do: :ok
end
