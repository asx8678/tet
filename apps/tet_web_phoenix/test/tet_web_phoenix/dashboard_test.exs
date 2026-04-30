defmodule TetWebPhoenix.TestEventLog do
  @moduledoc false

  @key {__MODULE__, :events}

  def put_events(events) when is_list(events) do
    Process.put(@key, events)
  end

  def list_events(session_id, _opts) when is_binary(session_id) or is_nil(session_id) do
    events = Process.get(@key, [])
    {:ok, Enum.filter(events, &matches_session?(&1, session_id))}
  end

  defp matches_session?(_event, nil), do: true

  defp matches_session?(%Tet.Event{session_id: event_session_id}, session_id),
    do: event_session_id == session_id

  defp matches_session?(_event, _session_id), do: false
end

defmodule TetWebPhoenix.DashboardTest do
  use ExUnit.Case, async: true

  alias TetWebPhoenix.Dashboard
  alias TetWebPhoenix.Dashboards.{Artifacts, RemoteStatus, RepairStatus, Tasks, Timeline}
  alias TetWebPhoenix.TestEventLog

  @tet_opts [store_adapter: TestEventLog]

  test "dashboard registry exposes the optional projection set" do
    assert TetWebPhoenix.dashboard_names() == [
             :timeline,
             :tasks,
             :artifacts,
             :repair,
             :remote_status
           ]

    assert {:error, {:unknown_dashboard, :nope}} = Dashboard.load(:nope, tet_opts: @tet_opts)
  end

  test "timeline renders all session Event Log rows through the facade" do
    TestEventLog.put_events([
      event(:session_started,
        sequence: 2,
        session_id: "alpha",
        payload: %{summary: "session booted"}
      ),
      event(:message_persisted,
        sequence: 1,
        session_id: "alpha",
        payload: %{role: :user, message_id: "msg-1"}
      ),
      event(:provider_done,
        sequence: 3,
        session_id: "beta",
        payload: %{summary: "do not show beta"}
      )
    ])

    assert {:ok, projection} = Timeline.load(session_id: "alpha", tet_opts: @tet_opts)

    assert projection.source == :event_log
    assert projection.event_count == 2
    assert Enum.map(projection.rows, & &1.sequence) == [1, 2]

    assert {:ok, html} = Timeline.render(session_id: "alpha", tet_opts: @tet_opts)
    assert html =~ ~s(data-source="event-log")
    assert html =~ "message_persisted"
    assert html =~ "session booted"
    refute html =~ "do not show beta"
  end

  test "domain dashboards project only matching Event Log rows" do
    TestEventLog.put_events(seed_events())

    cases = [
      {Tasks, :tasks, "task-1", "Write facade tests"},
      {Artifacts, :artifacts, "artifact-1", "priv/reports/dashboard.txt"},
      {RepairStatus, :repair, "repair-1", "compile failed &lt;boom&gt;"},
      {RemoteStatus, :remote_status, "ssh-builder", "builder.local"}
    ]

    for {module, id, expected_ref, expected_html} <- cases do
      assert {:ok, projection} = module.load(session_id: "alpha", tet_opts: @tet_opts)

      assert projection.id == id
      assert projection.source == :event_log
      assert projection.row_count == 1
      assert projection.rows |> List.first() |> Map.values() |> Enum.any?(&(&1 == expected_ref))

      html = module.render_projection(projection)
      assert html =~ expected_html
      assert html =~ ~s(data-source="event-log")
    end
  end

  test "root helpers and aliases return LiveView-friendly assigns" do
    TestEventLog.put_events(seed_events())

    assert {:ok, projection} =
             TetWebPhoenix.dashboard("repair_status", session_id: "alpha", tet_opts: @tet_opts)

    assert projection.id == :repair

    assert {:ok, html} =
             TetWebPhoenix.render_dashboard("remote", session_id: "alpha", tet_opts: @tet_opts)

    assert html =~ "Remote Status"
    assert html =~ "ssh-builder"

    assert {:ok, assigns} = Dashboard.assigns(:tasks, session_id: "alpha", tet_opts: @tet_opts)
    assert assigns.dashboard.id == :tasks
    assert assigns.html =~ "Write facade tests"
  end

  test "HTML renderer escapes Event Log values" do
    TestEventLog.put_events([
      event(:provider_error,
        sequence: 1,
        payload: %{
          dashboard: "repair",
          repair_id: "repair-x",
          reason: "bad <script>alert('nope')</script>"
        }
      )
    ])

    assert {:ok, html} = RepairStatus.render(session_id: "alpha", tet_opts: @tet_opts)

    assert html =~ "&lt;script&gt;alert('nope')&lt;/script&gt;"
    refute html =~ "<script>"
  end

  test "optional web source keeps Tet facade calls narrowed to event listing" do
    calls =
      "../../lib/**/*.ex"
      |> Path.expand(__DIR__)
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        ~r/\bTet\.(?!Event\b)[a-zA-Z_][a-zA-Z0-9_?!]*/
        |> Regex.scan(File.read!(path))
        |> Enum.map(fn [call] -> call end)
      end)
      |> Enum.uniq()
      |> Enum.sort()

    assert calls == ["Tet.list_events"]
  end

  defp seed_events do
    [
      event(:provider_done,
        sequence: 10,
        payload: %{
          dashboard: "task",
          task_id: "task-1",
          status: "running",
          title: "Write facade tests"
        }
      ),
      event(:message_persisted,
        sequence: 11,
        payload: %{
          dashboard: "artifact",
          artifact_id: "artifact-1",
          artifact_kind: "text",
          artifact_path: "priv/reports/dashboard.txt",
          status: "created"
        }
      ),
      event(:provider_error,
        sequence: 12,
        payload: %{
          dashboard: "repair",
          repair_id: "repair-1",
          status: "queued",
          reason: "compile failed <boom>"
        }
      ),
      event(:provider_usage,
        sequence: 13,
        payload: %{
          domain: "remote",
          remote_id: "ssh-builder",
          status: "healthy",
          host: "builder.local",
          heartbeat: "2026-04-30T12:00:00Z"
        }
      ),
      event(:provider_done,
        sequence: 14,
        session_id: "beta",
        payload: %{
          dashboard: "task",
          task_id: "task-beta",
          title: "wrong session"
        }
      )
    ]
  end

  defp event(type, attrs) do
    %Tet.Event{
      type: type,
      session_id: Keyword.get(attrs, :session_id, "alpha"),
      sequence: Keyword.fetch!(attrs, :sequence),
      payload: Keyword.get(attrs, :payload, %{}),
      metadata: Keyword.get(attrs, :metadata, %{timestamp: "2026-04-30T12:00:00Z"})
    }
  end
end
