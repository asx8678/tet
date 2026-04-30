defmodule TetWebPhoenix.Dashboards.Artifacts do
  @moduledoc """
  Artifact dashboard projected from Event Log records.
  """

  alias TetWebPhoenix.{EventDashboard, EventProjection}

  @markers [:artifact, :artifacts]
  @keys [:artifact_id, :artifact, :artifact_kind, :artifact_path, :digest]
  @fields [
    artifact_ref: [:artifact_id, :artifact, :id, :uri, :path],
    kind: [:artifact_kind, :kind, :mime_type],
    path: [:artifact_path, :path, :uri, :name],
    status: [:artifact_status, :status, :state]
  ]
  @columns [
    sequence_label: "Seq",
    artifact_ref: "Artifact",
    kind: "Kind",
    path: "Path",
    status: "Status",
    timestamp: "Time",
    summary: "Event"
  ]

  def load(opts \\ []) when is_list(opts) do
    EventDashboard.load(:artifacts, "Artifacts", opts, &row/1)
  end

  def project(events, opts \\ []) when is_list(events) and is_list(opts) do
    EventDashboard.project(:artifacts, "Artifacts", events, opts, &row/1)
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
      EventProjection.type_contains?(event, "artifact")
  end
end
