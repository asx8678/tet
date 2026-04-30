defmodule TetWebPhoenix.HTML do
  @moduledoc false

  alias TetWebPhoenix.EventProjection

  def dashboard(%{id: id, title: title, rows: rows} = projection, columns)
      when is_list(rows) and is_list(columns) do
    [
      ~s(<section class="tet-dashboard" data-dashboard="),
      attr(id),
      ~s(" data-source="event-log">),
      header(title, projection),
      body(rows, columns),
      "</section>"
    ]
    |> IO.iodata_to_binary()
  end

  defp header(title, projection) do
    [
      "<header>",
      "<h2>",
      text(title),
      "</h2>",
      ~s(<p class="tet-dashboard__source">Event Log projection only),
      session_suffix(Map.get(projection, :session_id)),
      "</p>",
      "</header>"
    ]
  end

  defp body([], _columns) do
    ~s(<p class="tet-dashboard__empty">No Event Log records match this dashboard.</p>)
  end

  defp body(rows, columns) do
    [
      ~s(<table class="tet-dashboard__table"><thead><tr>),
      Enum.map(columns, fn {_key, label} -> ["<th>", text(label), "</th>"] end),
      "</tr></thead><tbody>",
      Enum.map(rows, &row(&1, columns)),
      "</tbody></table>"
    ]
  end

  defp row(row, columns) do
    [
      "<tr>",
      Enum.map(columns, fn {key, _label} -> ["<td>", row_value(row, key), "</td>"] end),
      "</tr>"
    ]
  end

  defp row_value(row, key) do
    row
    |> Map.get(key)
    |> EventProjection.format()
    |> text()
  end

  defp session_suffix(nil), do: "."
  defp session_suffix(""), do: "."
  defp session_suffix(session_id), do: [" for session ", text(session_id), "."]

  defp text(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp attr(value) do
    value
    |> text()
    |> String.replace("\"", "&quot;")
  end
end
