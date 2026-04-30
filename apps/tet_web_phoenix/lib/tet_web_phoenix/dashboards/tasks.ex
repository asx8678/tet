defmodule TetWebPhoenix.Dashboards.Tasks do
  @moduledoc """
  Task dashboard projected from Event Log records.
  """

  alias TetWebPhoenix.{EventDashboard, EventProjection}

  @markers [:task, :tasks]
  @keys [:task_id, :task, :task_title, :task_status, :task_state]
  @fields [
    task_id: [:task_id, :task, :id],
    status: [:task_status, :status, :state, :phase],
    title: [:task_title, :title, :name, :description]
  ]
  @columns [
    sequence_label: "Seq",
    task_id: "Task",
    status: "Status",
    title: "Title",
    timestamp: "Time",
    summary: "Event"
  ]

  def load(opts \\ []) when is_list(opts) do
    EventDashboard.load(:tasks, "Tasks", opts, &row/1)
  end

  def project(events, opts \\ []) when is_list(events) and is_list(opts) do
    EventDashboard.project(:tasks, "Tasks", events, opts, &row/1)
  end

  def render(opts \\ []) when is_list(opts) do
    with {:ok, projection} <- load(opts) do
      {:ok, render_projection(projection)}
    end
  end

  def render_projection(projection) when is_map(projection) do
    EventDashboard.render(projection, @columns)
  end

  defp row(%Tet.Event{} = event) do
    if relevant?(event) do
      EventProjection.row(event, @fields)
    end
  end

  defp relevant?(%Tet.Event{} = event) do
    EventProjection.marked?(event, @markers) or
      EventProjection.has_any_key?(event, @keys) or
      EventProjection.type_contains?(event, "task")
  end
end
