defmodule Tet.SessionTest do
  use ExUnit.Case, async: true

  alias Tet.Runtime.{Session, SessionRegistry, State}

  setup do
    # Ensure the SessionRegistry and SessionSupervisor are started
    # (they're supervised in the app, but test async may run before app starts)
    unless Process.whereis(SessionRegistry.name()) do
      start_supervised!({Registry, keys: :unique, name: SessionRegistry.name()})
    end

    unless Process.whereis(Tet.Runtime.SessionSupervisor.name()) do
      start_supervised!(Tet.Runtime.SessionSupervisor)
    end

    :ok
  end

  # ── start_link / init ─────────────────────────────────────────────

  test "start_link/1 creates a session with the given state" do
    {:ok, pid} = Session.start_link(%{session_id: "ses_test_1", active_profile: "planner"})
    assert is_pid(pid)
    assert Session.get_session_id(pid) == "ses_test_1"
  end

  test "start_link/1 accepts a pre-built State struct" do
    {:ok, state} = State.new(%{session_id: "ses_test_struct", active_profile: "coder"})
    {:ok, pid} = Session.start_link(state)
    assert Session.get_state(pid).active_profile == %{id: "coder", options: %{}}
  end

  test "start_link/1 raises on invalid state attrs" do
    assert_raise ArgumentError, fn ->
      Session.start_link(%{session_id: ""})
    end
  end

  # ── Safe boundary swap (immediate) ────────────────────────────────

  test "request_swap at safe boundary applies immediately and emits applied event" do
    {:ok, pid} =
      Session.start_link(%{
        session_id: "ses_immediate",
        active_profile: "planner",
        event_sequence: 7
      })

    assert {:ok, state, events} = Session.request_swap(pid, "coder")

    assert state.active_profile == %{id: "coder", options: %{}}
    assert state.pending_profile_swap == nil

    # State refs preserved
    assert state.session_id == "ses_immediate"
    assert state.event_sequence == 7

    # Exactly one event emitted
    assert length(events) == 1
    assert hd(events).type == :profile_swap_applied
    assert hd(events).session_id == "ses_immediate"
    assert hd(events).payload.active_profile == %{id: "coder", options: %{}}
  end

  test "request_swap at safe boundary with profile ref preserves durable refs" do
    {:ok, pid} =
      Session.start_link(%{
        session_id: "ses_preserve",
        active_profile: "planner",
        history_ref: "hist_1",
        session_memory_ref: "smem_1",
        attachments: ["att_1"],
        active_task_refs: ["task_1"],
        artifact_refs: ["art_1"],
        approval_refs: ["appr_1"],
        cache_hints: %{provider: "openai"},
        context: %{compacted_ref: "ctx_1"},
        event_log_cursor: 42,
        event_sequence: 42
      })

    assert {:ok, state, _events} = Session.request_swap(pid, "reviewer")

    preserved = %{
      history_ref: "hist_1",
      session_memory_ref: "smem_1",
      attachments: ["att_1"],
      active_task_refs: ["task_1"],
      artifact_refs: ["art_1"],
      approval_refs: ["appr_1"],
      cache_hints: %{provider: "openai"},
      context: %{compacted_ref: "ctx_1"},
      event_log_cursor: 42
    }

    assert Map.take(state, Map.keys(preserved)) == preserved
    assert state.event_sequence == 42
  end

  # ── Mid-turn queue swap ───────────────────────────────────────────

  test "request_swap mid-turn with default mode queues and emits queued event" do
    {:ok, pid} =
      Session.start_link(%{
        session_id: "ses_queue",
        active_profile: "planner",
        event_sequence: 3
      })

    # Begin a turn first
    {:ok, _} = Session.begin_turn(pid)

    assert {:ok, state, events} = Session.request_swap(pid, "reviewer")

    # Profile not yet changed
    assert state.active_profile == %{id: "planner", options: %{}}
    assert state.pending_profile_swap != nil
    assert state.pending_profile_swap.to_profile == %{id: "reviewer", options: %{}}
    assert state.pending_profile_swap.mode == :queue_until_turn_boundary

    # Queued event emitted
    assert length(events) == 1
    assert hd(events).type == :profile_swap_queued
    assert hd(events).session_id == "ses_queue"
    assert hd(events).payload.to_profile == %{id: "reviewer", options: %{}}
    assert hd(events).payload.blocked_by == :in_turn
  end

  test "end_turn applies queued swap and emits applied event" do
    {:ok, pid} =
      Session.start_link(%{
        session_id: "ses_apply_queue",
        active_profile: "planner",
        event_sequence: 5
      })

    {:ok, _} = Session.begin_turn(pid)
    {:ok, _, _} = Session.request_swap(pid, "tester")

    # End turn - should apply the swap
    assert {:ok, state, events} = Session.end_turn(pid)

    assert state.active_profile == %{id: "tester", options: %{}}
    assert state.pending_profile_swap == nil
    assert state.turn_status == :idle

    # Applied event emitted
    assert length(events) == 1
    assert hd(events).type == :profile_swap_applied
    assert hd(events).session_id == "ses_apply_queue"
  end

  test "end_turn without pending swap returns empty events" do
    {:ok, pid} =
      Session.start_link(%{
        session_id: "ses_plain_end",
        active_profile: "planner"
      })

    {:ok, _} = Session.begin_turn(pid)
    assert {:ok, state, events} = Session.end_turn(pid)

    assert state.turn_status == :idle
    assert events == []
  end

  # ── Mid-turn reject swap ──────────────────────────────────────────

  test "request_swap mid-turn with reject mode returns error and emits rejected event" do
    {:ok, pid} =
      Session.start_link(%{
        session_id: "ses_reject",
        active_profile: "planner",
        event_sequence: 2
      })

    {:ok, _} = Session.begin_turn(pid)

    assert {:error, {:unsafe_profile_swap, request}} =
             Session.request_swap(pid, "tester", mode: :reject_mid_turn)

    assert request.to_profile == %{id: "tester", options: %{}}
    assert request.mode == :reject_mid_turn
    assert request.blocked_by == :in_turn
  end

  # ── Pending swap cannot be overwritten ────────────────────────────

  test "request_swap with existing pending swap returns error" do
    {:ok, pid} =
      Session.start_link(%{
        session_id: "ses_pending_block",
        active_profile: "planner"
      })

    {:ok, _} = Session.begin_turn(pid)
    {:ok, _, _} = Session.request_swap(pid, "coder")

    # Try to overwrite
    assert {:error, {:profile_swap_already_pending, _existing}} =
             Session.request_swap(pid, "tester")

    # State still has original pending
    state = Session.get_state(pid)
    assert state.pending_profile_swap.to_profile == %{id: "coder", options: %{}}
  end

  # ── begin_turn / put_turn_status / end_turn lifecycle ─────────────

  test "turn lifecycle transitions work correctly" do
    {:ok, pid} =
      Session.start_link(%{
        session_id: "ses_lifecycle",
        active_profile: "planner"
      })

    assert {:ok, state} = Session.begin_turn(pid)
    assert state.lifecycle == :active
    assert state.turn_status == :in_turn

    assert {:ok, state} = Session.put_turn_status(pid, :streaming)
    assert state.turn_status == :streaming

    assert {:ok, state, _events} = Session.end_turn(pid)
    assert state.turn_status == :idle
    assert state.lifecycle == :active
  end

  test "begin_turn on already in-turn returns error" do
    {:ok, pid} =
      Session.start_link(%{
        session_id: "ses_double_begin",
        active_profile: "planner"
      })

    {:ok, _} = Session.begin_turn(pid)
    assert {:error, {:invalid_turn_transition, :in_turn, :in_turn}} = Session.begin_turn(pid)
  end

  test "put_turn_status to idle returns error" do
    {:ok, pid} =
      Session.start_link(%{
        session_id: "ses_no_idle_put",
        active_profile: "planner"
      })

    {:ok, _} = Session.begin_turn(pid)

    assert {:error, {:invalid_turn_transition, :in_turn, :idle}} =
             Session.put_turn_status(pid, :idle)
  end

  test "end_turn on idle session returns error" do
    {:ok, pid} =
      Session.start_link(%{
        session_id: "ses_idle_end",
        active_profile: "planner"
      })

    assert {:error, {:invalid_turn_transition, :idle, :idle}} = Session.end_turn(pid)
  end

  # ── SessionRegistry integration ───────────────────────────────────

  test "session is registered with SessionRegistry on start via Tet facade" do
    # Use Tet.start_session to test the full flow
    {:ok, %{session_id: session_id, pid: pid}} = Tet.start_session("ws_1", profile: "planner")

    assert {:ok, ^pid} = SessionRegistry.lookup(session_id)
    assert SessionRegistry.list_sessions() |> Enum.member?(session_id)
  end

  test "SessionRegistry.lookup returns not_found for unknown session" do
    assert {:error, :session_not_found} = SessionRegistry.lookup("ses_nonexistent")
  end

  # ── Tet facade integration ────────────────────────────────────────

  test "Tet.switch_profile applies swap at safe boundary" do
    {:ok, %{session_id: ses_id, pid: _pid}} =
      Tet.start_session(nil, profile: "planner")

    assert {:ok, state, _events} = Tet.switch_profile(ses_id, "coder")
    assert state.active_profile == %{id: "coder", options: %{}}
  end

  test "Tet.switch_profile queues mid-turn" do
    {:ok, %{session_id: session_id, pid: pid}} =
      Tet.start_session(nil, profile: "planner")

    {:ok, _} = Session.begin_turn(pid)

    assert {:ok, state, _events} = Tet.switch_profile(session_id, "reviewer")
    assert state.active_profile == %{id: "planner", options: %{}}
    assert state.pending_profile_swap != nil
  end

  test "Tet.switch_profile with pid works" do
    {:ok, %{pid: pid}} = Tet.start_session(nil, profile: "planner")

    assert {:ok, state, _events} = Tet.switch_profile(pid, "coder")
    assert state.active_profile == %{id: "coder", options: %{}}
  end

  test "Tet.switch_profile with unknown session id returns error" do
    assert {:error, :session_not_found} = Tet.switch_profile("ses_nonexistent", "coder")
  end

  test "Tet.session_state returns the current state" do
    {:ok, %{session_id: session_id}} = Tet.start_session(nil, profile: "planner")

    assert {:ok, state} = Tet.session_state(session_id)
    assert state.active_profile == %{id: "planner", options: %{}}
    assert state.session_id == session_id
  end

  test "Tet.list_running_sessions returns running session ids" do
    {:ok, %{session_id: ses1}} = Tet.start_session(nil, profile: "planner")
    {:ok, %{session_id: ses2}} = Tet.start_session(nil, profile: "coder")

    assert {:ok, sessions} = Tet.list_running_sessions()
    assert ses1 in sessions
    assert ses2 in sessions
  end

  # ── Event emission verification ───────────────────────────────────

  test "swap events are published on EventBus topics" do
    # Subscribe to events
    Tet.Runtime.Timeline.subscribe()

    {:ok, %{session_id: ses_id, pid: _pid}} =
      Tet.start_session(nil, profile: "planner")

    # Do a safe-boundary swap
    Tet.switch_profile(ses_id, "coder")

    assert_received {:tet_event, :runtime_events, %Tet.Event{type: :profile_swap_applied}}
  end

  test "queued and applied events are published through EventBus on turn boundary" do
    Tet.Runtime.Timeline.subscribe()

    {:ok, %{session_id: _ses_id, pid: s_pid}} =
      Tet.start_session(nil, profile: "planner")

    # Begin turn and queue swap
    {:ok, _} = Session.begin_turn(s_pid)
    {:ok, _, _} = Session.request_swap(s_pid, "tester")

    assert_received {:tet_event, :runtime_events, %Tet.Event{type: :profile_swap_queued}}

    # End turn — should apply and emit
    {:ok, _, _} = Session.end_turn(s_pid)

    assert_received {:tet_event, :runtime_events, %Tet.Event{type: :profile_swap_applied}}
  end

  test "rejected swap emits rejected event through EventBus" do
    Tet.Runtime.Timeline.subscribe()

    {:ok, %{session_id: _ses_id, pid: s_pid}} =
      Tet.start_session(nil, profile: "planner")

    {:ok, _} = Session.begin_turn(s_pid)

    assert {:error, {:unsafe_profile_swap, _request}} =
             Session.request_swap(s_pid, "tester", mode: :reject_mid_turn)

    assert_received {:tet_event, :runtime_events, %Tet.Event{type: :profile_swap_rejected}}
  end

  # ── get_state returns consistent state ────────────────────────────

  test "get_state reflects latest profile after swap" do
    {:ok, pid} =
      Session.start_link(%{
        session_id: "ses_get_state",
        active_profile: "planner"
      })

    Session.request_swap(pid, "reviewer")
    state = Session.get_state(pid)
    assert state.active_profile == %{id: "reviewer", options: %{}}
  end

  test "get_state reflects queued swap" do
    {:ok, pid} =
      Session.start_link(%{
        session_id: "ses_queued_state",
        active_profile: "planner"
      })

    {:ok, _} = Session.begin_turn(pid)
    Session.request_swap(pid, "reviewer")

    state = Session.get_state(pid)
    assert state.active_profile == %{id: "planner", options: %{}}
    assert state.pending_profile_swap != nil
  end

  # ── Edge cases ────────────────────────────────────────────────────

  test "swap on terminal lifecycle returns unsafe error" do
    {:ok, pid} =
      Session.start_link(%{
        session_id: "ses_terminal",
        active_profile: "planner",
        lifecycle: :completed
      })

    assert {:error, {:unsafe_profile_swap, _}} = Session.request_swap(pid, "coder")
  end

  test "multiple sessions can be started independently" do
    {:ok, pid1} = Session.start_link(%{session_id: "ses_multi_1", active_profile: "planner"})
    {:ok, pid2} = Session.start_link(%{session_id: "ses_multi_2", active_profile: "coder"})

    assert Session.get_state(pid1).active_profile == %{id: "planner", options: %{}}
    assert Session.get_state(pid2).active_profile == %{id: "coder", options: %{}}
  end

  test "end_turn applies queued swap even after multiple turn status transitions" do
    {:ok, pid} =
      Session.start_link(%{
        session_id: "ses_multi_status",
        active_profile: "planner"
      })

    {:ok, _} = Session.begin_turn(pid)
    {:ok, _} = Session.put_turn_status(pid, :streaming)
    {:ok, _, _} = Session.request_swap(pid, "reviewer")
    {:ok, _} = Session.put_turn_status(pid, :tool_running)

    # End turn from tool_running
    assert {:ok, state, events} = Session.end_turn(pid)

    assert state.active_profile == %{id: "reviewer", options: %{}}
    assert state.pending_profile_swap == nil
    assert state.turn_status == :idle
    assert length(events) == 1
    assert hd(events).type == :profile_swap_applied
  end

  # ── Fix 2: Invalid request_swap handling ─────────────────────────

  test "request_swap with invalid profile returns error without crashing" do
    {:ok, pid} =
      Session.start_link(%{
        session_id: "ses_bad_profile",
        active_profile: "planner"
      })

    assert {:error, {:invalid_runtime_profile, _}} = Session.request_swap(pid, "")
    assert {:error, {:invalid_runtime_profile, _}} = Session.request_swap(pid, nil)
  end

  test "request_swap with invalid mode returns error without crashing" do
    {:ok, pid} =
      Session.start_link(%{
        session_id: "ses_bad_mode",
        active_profile: "planner"
      })

    assert {:error, {:invalid_runtime_state_field, :mode}} =
             Session.request_swap(pid, "coder", mode: :teleport)
  end

  test "request_swap with invalid cache_policy returns error without crashing" do
    {:ok, pid} =
      Session.start_link(%{
        session_id: "ses_bad_cache",
        active_profile: "planner"
      })

    assert {:error, {:invalid_runtime_state_field, :cache_policy}} =
             Session.request_swap(pid, "coder", cache_policy: :evaporate)
  end

  test "request_swap with invalid metadata returns error without crashing" do
    {:ok, pid} =
      Session.start_link(%{
        session_id: "ses_bad_meta",
        active_profile: "planner"
      })

    assert {:error, {:invalid_runtime_state_field, :metadata}} =
             Session.request_swap(pid, "coder", metadata: "not_a_map")
  end

  # ── Fix 4: SessionRegistry registers session pid, not caller pid ──

  test "SessionRegistry.lookup returns actual session pid from register in init" do
    {:ok, pid} =
      Session.start_link(%{
        session_id: "ses_reg_pid",
        active_profile: "planner"
      })

    # The pid returned by start_link IS the session pid
    assert {:ok, ^pid} = SessionRegistry.lookup("ses_reg_pid")

    # Verify we can talk to the session through the looked-up pid
    assert {:ok, session_pid} = SessionRegistry.lookup("ses_reg_pid")
    assert Session.get_session_id(session_pid) == "ses_reg_pid"
  end

  test "Tet.start_session via facade registers session correctly" do
    {:ok, %{session_id: session_id, pid: pid}} =
      Tet.start_session("ws_reg_test", profile: "planner")

    # The pid from Tet.start_session should match the registered pid
    assert {:ok, ^pid} = SessionRegistry.lookup(session_id)
  end

  # ── Fix 5: normalize_start_args ordering ─────────────────────────

  test "Tet.start_session with opts-only uses profile" do
    {:ok, %{session_id: _ses, pid: pid}} = Tet.start_session(profile: "coder")

    state = Session.get_state(pid)
    assert state.active_profile == %{id: "coder", options: %{}}
  end

  test "Tet.start_session with explicit nil workspace and profile opts" do
    {:ok, %{session_id: _ses, pid: pid}} = Tet.start_session(nil, profile: "reviewer")

    state = Session.get_state(pid)
    assert state.active_profile == %{id: "reviewer", options: %{}}
  end

  # ── Consistent swap_id across events ─────────────────────────────

  test "swap_id is consistent across queued and applied events" do
    Tet.Runtime.Timeline.subscribe()

    {:ok, %{session_id: _ses_id, pid: s_pid}} =
      Tet.start_session(nil, profile: "planner")

    {:ok, _} = Session.begin_turn(s_pid)
    {:ok, _, events} = Session.request_swap(s_pid, "tester")

    assert length(events) == 1
    queued_swap_id = events |> hd() |> Map.get(:metadata) |> Map.get(:swap_id)
    assert String.starts_with?(queued_swap_id, "swp_")

    # End turn should produce applied event with same swap_id
    {:ok, _, events} = Session.end_turn(s_pid)

    assert length(events) == 1
    applied_swap_id = events |> hd() |> Map.get(:metadata) |> Map.get(:swap_id)
    assert applied_swap_id == queued_swap_id
  end

  test "swap_id is consistent across reject events" do
    {:ok, %{session_id: _ses_id, pid: s_pid}} =
      Tet.start_session(nil, profile: "planner")

    {:ok, _} = Session.begin_turn(s_pid)

    assert {:error, {:unsafe_profile_swap, _request}} =
             Session.request_swap(s_pid, "tester",
               mode: :reject_mid_turn,
               metadata: %{reason: "manual"}
             )
  end
end
