defmodule Tet.Runtime.GuidanceLoopTest do
  use ExUnit.Case, async: true

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
        GuidanceLoop.ingest_decision(pid, %{
          type: :focus,
          guidance_message: "Focus on the auth module."
        },
          session_id: "ses_1",
          event_seq: 5
        )

      # Allow GenServer cast to process
      Process.sleep(10)

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
        GuidanceLoop.ingest_decision(pid, %{
          type: :guide,
          guidance_message: "Consider reviewing the contract."
        },
          session_id: "ses_1",
          event_seq: 3
        )

      Process.sleep(10)

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

      Process.sleep(10)
      assert GuidanceLoop.get_active_guidance(pid) == []
    end

    test "ignores block decisions (no guidance)" do
      {:ok, pid} = GuidanceLoop.start_link([])

      :ok =
        GuidanceLoop.ingest_decision(pid, %{type: :block, reason: "nope"},
          session_id: "ses_1",
          event_seq: 2
        )

      Process.sleep(10)
      assert GuidanceLoop.get_active_guidance(pid) == []
    end

    test "expires old guidance on new decision ingest" do
      {:ok, pid} = GuidanceLoop.start_link([])

      # First decision
      :ok =
        GuidanceLoop.ingest_decision(pid, %{
          type: :guide,
          guidance_message: "First guidance."
        },
          session_id: "ses_1",
          event_seq: 1
        )

      Process.sleep(10)
      assert length(GuidanceLoop.get_active_guidance(pid)) == 1

      # Second decision — should expire the first
      :ok =
        GuidanceLoop.ingest_decision(pid, %{
          type: :guide,
          guidance_message: "Second guidance."
        },
          session_id: "ses_1",
          event_seq: 2
        )

      Process.sleep(10)

      active = GuidanceLoop.get_active_guidance(pid)
      assert length(active) == 1
      assert hd(active).message == "Second guidance."
    end

    test "stores multiple guidances with trigger event references" do
      {:ok, pid} = GuidanceLoop.start_link([])

      :ok =
        GuidanceLoop.ingest_decision(pid, %{
          type: :guide,
          guidance_message: "Check the logs."
        },
          session_id: "ses_1",
          event_seq: 7,
          trigger_event_type: :"tool.finished",
          trigger_event_seq: 7
        )

      Process.sleep(10)

      [msg] = GuidanceLoop.get_active_guidance(pid)
      assert msg.trigger_event_type == :"tool.finished"
      assert msg.trigger_event_seq == 7
    end
  end

  describe "get_all_guidance/1" do
    test "returns all messages (active + expired)" do
      {:ok, pid} = GuidanceLoop.start_link([])

      :ok =
        GuidanceLoop.ingest_decision(pid, %{
          type: :guide,
          guidance_message: "First."
        },
          session_id: "ses_1",
          event_seq: 1
        )

      Process.sleep(10)

      :ok =
        GuidanceLoop.ingest_decision(pid, %{
          type: :guide,
          guidance_message: "Second."
        },
          session_id: "ses_1",
          event_seq: 2
        )

      Process.sleep(10)

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
        Tet.Event.steering_decision(%{
          decision: %{
            type: :focus,
            guidance_message: "Focus on security."
          }
        },
          session_id: "ses_event",
          sequence: 10
        )

      Tet.EventBus.publish(Tet.Runtime.Timeline.all_topic(), event)
      Process.sleep(20)

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
      Process.sleep(10)

      assert GuidanceLoop.get_active_guidance(pid) == []
    end

    test "expires on new tool events" do
      {:ok, pid} = GuidanceLoop.start_link([])

      # Ingest via the decision API
      :ok =
        GuidanceLoop.ingest_decision(pid, %{
          type: :guide,
          guidance_message: "Old guidance."
        },
          session_id: "ses_event",
          event_seq: 1
        )

      Process.sleep(10)
      assert length(GuidanceLoop.get_active_guidance(pid)) == 1

      # New tool event via bus — should expire old guidance
      # (no decision in payload, so no new guidance added, but old expires)
      event =
        Tet.Event.steering_decision(%{
          decision: %{
            type: :focus,
            guidance_message: "New focus."
          }
        },
          session_id: "ses_event",
          sequence: 5
        )

      Tet.EventBus.publish(Tet.Runtime.Timeline.all_topic(), event)
      Process.sleep(20)

      active = GuidanceLoop.get_active_guidance(pid)
      assert length(active) == 1
      assert hd(active).message == "New focus."
    end
  end
end
