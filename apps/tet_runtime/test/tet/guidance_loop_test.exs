defmodule Tet.Runtime.GuidanceLoopTest do
  use ExUnit.Case

  alias Tet.Runtime.GuidanceLoop
  alias Tet.Steering.GuidanceMessage

  setup do
    # Start the EventBus registry
    unless Tet.EventBus.started?() do
      start_supervised!({Registry, keys: :duplicate, name: Tet.EventBus.Registry})
    end

    # Start the guidance loop
    %{loop: start_supervised!(GuidanceLoop.child_spec([]))}
  end

  describe "start_link/1" do
    test "starts the guidance loop" do
      {:ok, pid} = GuidanceLoop.start_link([])
      assert is_pid(pid)
      assert GuidanceLoop.get_active_guidance(pid) == []
    end
  end

  describe "get_active_guidance/1" do
    test "returns empty list initially" do
      {:ok, pid} = GuidanceLoop.start_link([])
      assert GuidanceLoop.get_active_guidance(pid) == []
    end
  end

  describe "ingest_decision/3" do
    test "ingests a focus decision and stores guidance" do
      {:ok, pid} = GuidanceLoop.start_link([])

      :ok =
        GuidanceLoop.ingest_decision(
          pid,
          %{
            type: :focus,
            guidance_message: "Focus on the auth module."
          },
          session_id: "ses_1",
          event_seq: 5
        )

      GuidanceLoop.sync(pid)

      active = GuidanceLoop.get_active_guidance(pid)
      assert length(active) == 1

      msg = hd(active)
      assert msg.decision_type == :focus
      assert msg.message == "Focus on the auth module."
      assert msg.session_id == "ses_1"
      assert msg.event_seq == 5
    end

    test "ingests a guide decision" do
      {:ok, pid} = GuidanceLoop.start_link([])

      :ok =
        GuidanceLoop.ingest_decision(
          pid,
          %{
            type: :guide,
            guidance_message: "Consider reviewing the contract."
          },
          session_id: "ses_1",
          event_seq: 3
        )

      GuidanceLoop.sync(pid)

      active = GuidanceLoop.get_active_guidance(pid)
      assert length(active) == 1
      assert hd(active).decision_type == :guide
    end

    test "ignores continue decisions (no guidance)" do
      {:ok, pid} = GuidanceLoop.start_link([])

      :ok =
        GuidanceLoop.ingest_decision(pid, %{type: :continue},
          session_id: "ses_1",
          event_seq: 1
        )

      GuidanceLoop.sync(pid)
      assert GuidanceLoop.get_active_guidance(pid) == []
    end

    test "ignores block decisions (no guidance)" do
      {:ok, pid} = GuidanceLoop.start_link([])

      :ok =
        GuidanceLoop.ingest_decision(pid, %{type: :block, reason: "nope"},
          session_id: "ses_1",
          event_seq: 2
        )

      GuidanceLoop.sync(pid)
      assert GuidanceLoop.get_active_guidance(pid) == []
    end

    test "expires old guidance on new decision ingest (session-scoped)" do
      {:ok, pid} = GuidanceLoop.start_link([])

      # First decision
      :ok =
        GuidanceLoop.ingest_decision(
          pid,
          %{
            type: :guide,
            guidance_message: "First guidance."
          },
          session_id: "ses_1",
          event_seq: 1
        )

      GuidanceLoop.sync(pid)
      assert length(GuidanceLoop.get_active_guidance(pid)) == 1

      # Second decision for same session — should expire the first
      :ok =
        GuidanceLoop.ingest_decision(
          pid,
          %{
            type: :guide,
            guidance_message: "Second guidance."
          },
          session_id: "ses_1",
          event_seq: 2
        )

      GuidanceLoop.sync(pid)

      active = GuidanceLoop.get_active_guidance(pid)
      assert length(active) == 1
      assert hd(active).message == "Second guidance."
    end

    test "session isolation: different sessions do not expire each other" do
      {:ok, pid} = GuidanceLoop.start_link([])

      # First session ingest
      :ok =
        GuidanceLoop.ingest_decision(
          pid,
          %{
            type: :guide,
            guidance_message: "Session A guidance."
          },
          session_id: "ses_a",
          event_seq: 1
        )

      GuidanceLoop.sync(pid)

      # Second session ingest — should NOT expire ses_a guidance
      :ok =
        GuidanceLoop.ingest_decision(
          pid,
          %{
            type: :guide,
            guidance_message: "Session B guidance."
          },
          session_id: "ses_b",
          event_seq: 2
        )

      GuidanceLoop.sync(pid)

      # Both sessions should still have active guidance
      active = GuidanceLoop.get_active_guidance(pid)
      assert length(active) == 2

      # Each session has its own active guidance
      ses_a_active = GuidanceLoop.get_active_guidance_for_session(pid, "ses_a")
      ses_b_active = GuidanceLoop.get_active_guidance_for_session(pid, "ses_b")
      assert length(ses_a_active) == 1
      assert length(ses_b_active) == 1
    end

    test "stores multiple guidances with trigger event references" do
      {:ok, pid} = GuidanceLoop.start_link([])

      :ok =
        GuidanceLoop.ingest_decision(
          pid,
          %{
            type: :guide,
            guidance_message: "Check the logs."
          },
          session_id: "ses_1",
          event_seq: 7,
          trigger_event_type: :"tool.finished",
          trigger_event_seq: 7
        )

      GuidanceLoop.sync(pid)

      [msg] = GuidanceLoop.get_active_guidance(pid)
      assert msg.trigger_event_type == :"tool.finished"
      assert msg.trigger_event_seq == 7
    end
  end

  describe "get_all_guidance/1" do
    test "returns all messages (active + expired)" do
      {:ok, pid} = GuidanceLoop.start_link([])

      :ok =
        GuidanceLoop.ingest_decision(
          pid,
          %{
            type: :guide,
            guidance_message: "First."
          },
          session_id: "ses_1",
          event_seq: 1
        )

      GuidanceLoop.sync(pid)

      :ok =
        GuidanceLoop.ingest_decision(
          pid,
          %{
            type: :guide,
            guidance_message: "Second."
          },
          session_id: "ses_1",
          event_seq: 2
        )

      GuidanceLoop.sync(pid)

      all = GuidanceLoop.get_all_guidance(pid)
      assert length(all) == 2

      # Second is still active, first is expired
      active = Enum.filter(all, &GuidanceMessage.active?/1)
      expired = Enum.reject(all, &GuidanceMessage.active?/1)
      assert length(active) == 1
      assert length(expired) == 1
    end
  end

  describe "event bus integration" do
    test "handles steering_decision events from the event bus" do
      {:ok, pid} = GuidanceLoop.start_link([])

      event =
        Tet.Event.steering_decision(
          %{
            decision: %{
              type: :focus,
              guidance_message: "Focus on security."
            }
          },
          session_id: "ses_event",
          sequence: 10
        )

      Tet.EventBus.publish(Tet.Runtime.Timeline.all_topic(), event)
      GuidanceLoop.sync(pid)

      active = GuidanceLoop.get_active_guidance(pid)
      assert length(active) == 1
      assert hd(active).decision_type == :focus
      assert hd(active).message == "Focus on security."
    end

    test "ignores non-task/tool events" do
      {:ok, pid} = GuidanceLoop.start_link([])

      event =
        Tet.Event.provider_start(%{provider: :test},
          session_id: "ses_event",
          sequence: 1
        )

      Tet.EventBus.publish(Tet.Runtime.Timeline.all_topic(), event)
      GuidanceLoop.sync(pid)

      assert GuidanceLoop.get_active_guidance(pid) == []
    end

    test "expires on new tool events (session-scoped)" do
      {:ok, pid} = GuidanceLoop.start_link([])

      # Ingest via the decision API
      :ok =
        GuidanceLoop.ingest_decision(
          pid,
          %{
            type: :guide,
            guidance_message: "Old guidance."
          },
          session_id: "ses_event",
          event_seq: 1
        )

      GuidanceLoop.sync(pid)
      assert length(GuidanceLoop.get_active_guidance(pid)) == 1

      # New tool event via bus — should expire old guidance for same session
      event =
        Tet.Event.steering_decision(
          %{
            decision: %{
              type: :focus,
              guidance_message: "New focus."
            }
          },
          session_id: "ses_event",
          sequence: 5
        )

      Tet.EventBus.publish(Tet.Runtime.Timeline.all_topic(), event)
      GuidanceLoop.sync(pid)

      active = GuidanceLoop.get_active_guidance(pid)
      assert length(active) == 1
      assert hd(active).message == "New focus."
    end

    test "event bus: session isolation across different sessions" do
      {:ok, pid} = GuidanceLoop.start_link([])

      # Ingest guidance for ses_a
      event_a =
        Tet.Event.steering_decision(
          %{
            decision: %{
              type: :guide,
              guidance_message: "Session A guidance."
            }
          },
          session_id: "ses_a",
          sequence: 1
        )

      Tet.EventBus.publish(Tet.Runtime.Timeline.all_topic(), event_a)
      GuidanceLoop.sync(pid)

      # New event for ses_b should NOT expire ses_a's guidance
      event_b =
        Tet.Event.steering_decision(
          %{
            decision: %{
              type: :guide,
              guidance_message: "Session B guidance."
            }
          },
          session_id: "ses_b",
          sequence: 2
        )

      Tet.EventBus.publish(Tet.Runtime.Timeline.all_topic(), event_b)
      GuidanceLoop.sync(pid)

      ses_a_active = GuidanceLoop.get_active_guidance_for_session(pid, "ses_a")
      ses_b_active = GuidanceLoop.get_active_guidance_for_session(pid, "ses_b")

      assert length(ses_a_active) == 1
      assert length(ses_b_active) == 1
      assert hd(ses_a_active).message == "Session A guidance."
      assert hd(ses_b_active).message == "Session B guidance."
    end
  end
end
