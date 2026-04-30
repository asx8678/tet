defmodule TetWebPhoenix.Dashboards.RemoteStatus do
  @moduledoc """
  Remote status dashboard projected from Event Log records.
  """

  alias TetWebPhoenix.{EventDashboard, EventProjection}

  @markers [:remote, :remote_status, :remote_worker]
  @keys [:remote_id, :worker_id, :remote_status, :heartbeat, :lease_id]
  @fields [
    remote_ref: [:remote_id, :worker_id, :lease_id, :id],
    status: [:remote_status, :status, :state],
    host: [:host, :node, :target],
    heartbeat: [:heartbeat, :heartbeat_at, :last_seen_at],
    profile: [:profile, :remote_profile]
  ]
  @columns [
    sequence_label: "Seq",
    remote_ref: "Remote",
    status: "Status",
    host: "Host",
    heartbeat: "Heartbeat",
    profile: "Profile",
    timestamp: "Time"
  ]

  def load(opts \\ []) when is_list(opts) do
    EventDashboard.load(:remote_status, "Remote Status", opts, &row/1)
  end

  def project(events, opts \\ []) when is_list(events) and is_list(opts) do
    EventDashboard.project(:remote_status, "Remote Status", events, opts, &row/1)
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
      EventProjection.type_contains?(event, "remote")
  end
end
