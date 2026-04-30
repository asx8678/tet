defmodule TetWebPhoenix.Dashboards.Timeline do
  @moduledoc """
  Timeline dashboard projected from Event Log records.
  """

  alias TetWebPhoenix.{EventDashboard, EventProjection}

  @columns [
    sequence_label: "Seq",
    timestamp: "Time",
    session_label: "Session",
    type: "Type",
    summary: "Summary"
  ]

  def load(opts \\ []) when is_list(opts) do
    EventDashboard.load(:timeline, "Timeline", opts, &row/1)
  end

  def project(events, opts \\ []) when is_list(events) and is_list(opts) do
    EventDashboard.project(:timeline, "Timeline", events, opts, &row/1)
  end

  def render(opts \\ []) when is_list(opts) do
    with {:ok, projection} <- load(opts) do
      {:ok, render_projection(projection)}
    end
  end

  def render_projection(projection) when is_map(projection) do
    EventDashboard.render(projection, @columns)
  end

  defp row(%Tet.Event{} = event), do: EventProjection.row(event)
end
