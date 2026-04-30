defmodule TetWebPhoenix.EventDashboard do
  @moduledoc false

  alias TetWebPhoenix.{EventLog, HTML}

  def load(id, title, opts, row_fun)
      when is_atom(id) and is_binary(title) and is_list(opts) and is_function(row_fun, 1) do
    with {:ok, events} <- EventLog.list(opts) do
      {:ok, project(id, title, events, opts, row_fun)}
    end
  end

  def project(id, title, events, opts, row_fun)
      when is_atom(id) and is_binary(title) and is_list(events) and is_list(opts) and
             is_function(row_fun, 1) do
    rows =
      events
      |> Enum.map(row_fun)
      |> Enum.reject(&is_nil/1)

    %{
      id: id,
      title: title,
      source: :event_log,
      session_id: Keyword.get(opts, :session_id),
      row_count: length(rows),
      event_count: length(events),
      rows: rows
    }
  end

  def render(projection, columns) when is_map(projection) and is_list(columns) do
    HTML.dashboard(projection, columns)
  end
end
