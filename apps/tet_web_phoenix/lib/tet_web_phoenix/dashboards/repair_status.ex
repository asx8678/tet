defmodule TetWebPhoenix.Dashboards.RepairStatus do
  @moduledoc """
  Repair status dashboard projected from Event Log records.
  """

  alias TetWebPhoenix.{EventDashboard, EventProjection}

  @markers [:repair, :repairs, :repair_queue, :error_log, :error]
  @keys [:repair_id, :error_id, :repair_status, :repair_phase]
  @error_types [:provider_error, :provider_route_error]
  @fields [
    repair_ref: [:repair_id, :error_id, :id],
    status: [:repair_status, :status, :state],
    phase: [:repair_phase, :phase, :step],
    reason: [:reason, :kind, :detail],
    outcome: [:outcome, :result]
  ]
  @columns [
    sequence_label: "Seq",
    repair_ref: "Repair",
    status: "Status",
    phase: "Phase",
    reason: "Reason",
    outcome: "Outcome",
    timestamp: "Time"
  ]

  def load(opts \\ []) when is_list(opts) do
    EventDashboard.load(:repair, "Repair", opts, &row/1)
  end

  def project(events, opts \\ []) when is_list(events) and is_list(opts) do
    EventDashboard.project(:repair, "Repair", events, opts, &row/1)
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

  defp relevant?(%Tet.Event{type: type} = event) do
    type in @error_types or
      EventProjection.marked?(event, @markers) or
      EventProjection.has_any_key?(event, @keys) or
      EventProjection.type_contains?(event, "repair")
  end
end
