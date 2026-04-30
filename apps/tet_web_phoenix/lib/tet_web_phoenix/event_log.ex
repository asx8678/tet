defmodule TetWebPhoenix.EventLog do
  @moduledoc """
  Facade-only Event Log loader used by every dashboard projection.

  This is the only place in the optional adapter shell that calls the root Tet
  facade. It deliberately asks for Event Log data and nothing else.
  """

  @doc "Lists Event Log records for dashboard projection."
  def list(opts \\ []) when is_list(opts) do
    with {:ok, session_id} <- session_id(opts),
         {:ok, tet_opts} <- tet_opts(opts),
         {:ok, limit} <- limit(opts),
         {:ok, events} <- fetch_events(session_id, tet_opts) do
      {:ok,
       events
       |> Enum.sort_by(&sort_key/1)
       |> maybe_limit(limit)}
    end
  end

  defp fetch_events(nil, tet_opts), do: Tet.list_events(tet_opts)
  defp fetch_events(session_id, tet_opts), do: Tet.list_events(session_id, tet_opts)

  defp session_id(opts) do
    case Keyword.get(opts, :session_id) do
      nil ->
        {:ok, nil}

      session_id when is_binary(session_id) ->
        session_id = String.trim(session_id)
        {:ok, if(session_id == "", do: nil, else: session_id)}

      session_id ->
        {:error, {:invalid_dashboard_option, :session_id, session_id}}
    end
  end

  defp tet_opts(opts) do
    case Keyword.get(opts, :tet_opts, []) do
      tet_opts when is_list(tet_opts) -> {:ok, tet_opts}
      tet_opts -> {:error, {:invalid_dashboard_option, :tet_opts, tet_opts}}
    end
  end

  defp limit(opts) do
    case Keyword.get(opts, :limit) do
      nil -> {:ok, nil}
      limit when is_integer(limit) and limit > 0 -> {:ok, limit}
      limit -> {:error, {:invalid_dashboard_option, :limit, limit}}
    end
  end

  defp sort_key(%Tet.Event{sequence: sequence}) when is_integer(sequence) do
    {0, sequence}
  end

  defp sort_key(%Tet.Event{} = event) do
    timestamp =
      event.metadata
      |> value(:timestamp)
      |> Kernel.||(value(event.payload, :timestamp))
      |> to_string()

    {1, timestamp, Atom.to_string(event.type)}
  end

  defp maybe_limit(events, nil), do: events
  defp maybe_limit(events, limit), do: Enum.take(events, limit)

  defp value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp value(_map, _key), do: nil
end
