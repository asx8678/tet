defmodule Tet.EventTest do
  use ExUnit.Case, async: true

  alias Tet.Event

  describe "profile swap events" do
    test "profile_swap_queued/2 builds a queued event" do
      event =
        Event.profile_swap_queued(
          %{
            from_profile: %{id: "planner"},
            to_profile: %{id: "coder"},
            mode: :queue_until_turn_boundary,
            blocked_by: :in_turn
          },
          session_id: "ses_1",
          sequence: 5,
          metadata: %{swap_id: "swp_1"}
        )

      assert event.type == :profile_swap_queued
      assert event.session_id == "ses_1"
      assert event.sequence == 5
      assert event.payload.from_profile == %{id: "planner"}
      assert event.payload.to_profile == %{id: "coder"}
      assert event.payload.mode == :queue_until_turn_boundary
      assert event.payload.blocked_by == :in_turn
      assert event.metadata.swap_id == "swp_1"
    end

    test "profile_swap_applied/2 builds an applied event" do
      event =
        Event.profile_swap_applied(
          %{
            active_profile: %{id: "reviewer", options: %{}},
            pending_profile_swap: nil
          },
          session_id: "ses_2",
          metadata: %{swap_id: "swp_2"}
        )

      assert event.type == :profile_swap_applied
      assert event.session_id == "ses_2"
      assert event.payload.active_profile == %{id: "reviewer", options: %{}}
      assert event.payload.pending_profile_swap == nil
      assert event.metadata.swap_id == "swp_2"
    end

    test "profile_swap_rejected/2 builds a rejected event" do
      event =
        Event.profile_swap_rejected(
          %{
            from_profile: %{id: "planner"},
            to_profile: %{id: "tester"},
            mode: :reject_mid_turn,
            reason: :mid_turn_rejected,
            blocked_by: :in_turn
          },
          session_id: "ses_3"
        )

      assert event.type == :profile_swap_rejected
      assert event.session_id == "ses_3"
      assert event.payload.from_profile == %{id: "planner"}
      assert event.payload.to_profile == %{id: "tester"}
      assert event.payload.mode == :reject_mid_turn
      assert event.payload.reason == :mid_turn_rejected
    end

    test "profile swap types are listed in known_types" do
      assert :profile_swap_queued in Event.known_types()
      assert :profile_swap_applied in Event.known_types()
      assert :profile_swap_rejected in Event.known_types()
    end

    test "profile_swap_types/0 returns the swap event types" do
      assert Event.profile_swap_types() == [
               :profile_swap_queued,
               :profile_swap_applied,
               :profile_swap_rejected
             ]
    end

    test "profile swap events round-trip through to_map/1 and from_map/1 with string keys" do
      original =
        Event.profile_swap_applied(
          %{
            active_profile: %{id: "coder", options: %{"mode" => "act"}},
            pending_profile_swap: nil
          },
          session_id: "ses_rt",
          sequence: 7
        )

      mapped = Event.to_map(original)
      # to_map stringifies keys, so from_map should still validate
      assert {:ok, roundtripped} = Event.from_map(mapped)

      # After round-trip, payload keys are strings (JSON convention)
      assert roundtripped.type == original.type
      assert roundtripped.session_id == original.session_id
      assert roundtripped.sequence == original.sequence
      assert roundtripped.payload["active_profile"]["id"] == "coder"
      assert roundtripped.payload["pending_profile_swap"] == nil
    end
  end

  describe "artifact.created events" do
    test "artifact_created/2 builds an artifact.created event" do
      event =
        Event.artifact_created(
          %{
            artifact_id: "art_1",
            tool_call_id: "call_1",
            file_path: "/lib/foo.ex",
            snapshot_before_id: "snap_b",
            snapshot_after_id: "snap_a"
          },
          session_id: "ses_art",
          seq: 5,
          metadata: %{source: :mutation}
        )

      assert event.type == :"artifact.created"
      assert event.payload.artifact_id == "art_1"
      assert event.payload.tool_call_id == "call_1"
      assert event.payload.file_path == "/lib/foo.ex"
      assert event.payload.snapshot_before_id == "snap_b"
      assert event.payload.snapshot_after_id == "snap_a"
      assert event.session_id == "ses_art"
      assert event.seq == 5
      assert event.metadata.source == :mutation
    end

    test "artifact.created type is in known_types" do
      assert :"artifact.created" in Event.known_types()
    end

    test "artifact_types/0 returns artifact event types" do
      assert Event.artifact_types() == [:"artifact.created"]
    end

    test "artifact.created event round-trips through to_map/1 and from_map/1" do
      original =
        Event.artifact_created(
          %{
            artifact_id: "art_rt",
            tool_call_id: "call_rt",
            file_path: "/lib/bar.ex",
            snapshot_before_id: "sb",
            snapshot_after_id: "sa"
          },
          session_id: "ses_rt",
          seq: 10
        )

      mapped = Event.to_map(original)
      assert {:ok, roundtripped} = Event.from_map(mapped)

      assert roundtripped.type == original.type
      assert roundtripped.session_id == original.session_id
      assert roundtripped.seq == original.seq
      assert roundtripped.payload["artifact_id"] == "art_rt"
      assert roundtripped.payload["file_path"] == "/lib/bar.ex"
    end
  end

  describe "blocked_action.created events" do
    test "blocked_action/2 builds a blocked_action.created event" do
      event =
        Event.blocked_action(
          %{
            blocked_action_id: "blk_1",
            tool_name: "write-file",
            reason: :plan_mode_blocks_mutation,
            tool_call_id: "call_blk"
          },
          session_id: "ses_blk",
          seq: 7,
          metadata: %{risk: :high}
        )

      assert event.type == :"blocked_action.created"
      assert event.payload.blocked_action_id == "blk_1"
      assert event.payload.tool_name == "write-file"
      assert event.payload.reason == :plan_mode_blocks_mutation
      assert event.payload.tool_call_id == "call_blk"
      assert event.session_id == "ses_blk"
      assert event.seq == 7
      assert event.metadata.risk == :high
    end

    test "blocked_action.created type is in known_types" do
      assert :"blocked_action.created" in Event.known_types()
    end

    test "blocked_action_types/0 returns blocked-action event types" do
      assert Event.blocked_action_types() == [:"blocked_action.created"]
    end

    test "blocked_action.created event round-trips through to_map/1 and from_map/1" do
      original =
        Event.blocked_action(
          %{
            blocked_action_id: "blk_rt",
            tool_name: "shell",
            reason: :no_active_task,
            tool_call_id: "call_rt"
          },
          session_id: "ses_rt",
          seq: 12
        )

      mapped = Event.to_map(original)
      assert {:ok, roundtripped} = Event.from_map(mapped)

      assert roundtripped.type == original.type
      assert roundtripped.session_id == original.session_id
      assert roundtripped.seq == original.seq
      assert roundtripped.payload["blocked_action_id"] == "blk_rt"
      assert roundtripped.payload["tool_name"] == "shell"
      assert roundtripped.payload["reason"] == "no_active_task"
    end
  end

  describe "full audit story event round-trip" do
    test "approval lifecycle + artifact + blocked-action events round-trip through serialization" do
      # Build a complete audit story as events
      events = [
        Event.approval_created(
          %{approval_id: "a1", tool_call_id: "c1", status: :pending},
          session_id: "ses_audit",
          seq: 1,
          metadata: %{task_id: "t1"}
        ),
        Event.artifact_created(
          %{
            artifact_id: "art_1",
            tool_call_id: "c1",
            file_path: "/lib/foo.ex",
            snapshot_before_id: "sb",
            snapshot_after_id: "sa"
          },
          session_id: "ses_audit",
          seq: 2
        ),
        Event.approval_approved(
          %{approval_id: "a1", tool_call_id: "c1", approver: "adam", rationale: "OK"},
          session_id: "ses_audit",
          seq: 3
        ),
        Event.blocked_action(
          %{
            blocked_action_id: "blk_1",
            tool_name: "write-file",
            reason: :mode_not_allowed,
            tool_call_id: "c2"
          },
          session_id: "ses_audit",
          seq: 4
        )
      ]

      # All events have correct types
      assert Enum.map(events, & &1.type) == [
               :"approval.created",
               :"artifact.created",
               :"approval.approved",
               :"blocked_action.created"
             ]

      # All events share session_id
      for event <- events do
        assert event.session_id == "ses_audit"
      end

      # All events round-trip individually through to_map/from_map
      for event <- events do
        mapped = Event.to_map(event)
        assert {:ok, restored} = Event.from_map(mapped)
        assert restored.type == event.type
        assert restored.session_id == event.session_id
        assert restored.seq == event.seq
      end
    end
  end

  describe "steering decision events" do
    test "steering_decision/2 builds a steering decision event" do
      event =
        Event.steering_decision(
          %{
            decision: %{type: "block", reason: "unsafe", confidence: 0.99},
            context_summary: %{active_task: "T1", session_age: 42}
          },
          session_id: "ses_steer",
          sequence: 10,
          metadata: %{evaluator: "llm"}
        )

      assert event.type == :steering_decision
      assert event.session_id == "ses_steer"
      assert event.sequence == 10
      assert event.payload.decision == %{type: "block", reason: "unsafe", confidence: 0.99}
      assert event.payload.context_summary == %{active_task: "T1", session_age: 42}
      assert event.metadata.evaluator == "llm"
    end

    test "steering_decision/2 works with minimal options" do
      event = Event.steering_decision(%{decision: %{type: :continue}})
      assert event.type == :steering_decision
      assert event.payload.decision.type == :continue
      assert event.session_id == nil
      assert event.sequence == nil
      assert event.metadata == %{}
    end

    test "steering decision type is listed in known_types" do
      assert :steering_decision in Event.known_types()
    end

    test "steering_types/0 returns the steering event types" do
      assert Event.steering_types() == [:steering_decision]
    end

    test "steering decision event round-trips through to_map/1 and from_map/1" do
      original =
        Event.steering_decision(
          %{
            decision: %{type: "block", reason: "unsafe", confidence: 0.95},
            context_summary: %{active_task: "T1", session_age: 100}
          },
          session_id: "ses_rt2",
          sequence: 15
        )

      mapped = Event.to_map(original)
      assert {:ok, roundtripped} = Event.from_map(mapped)

      assert roundtripped.type == original.type
      assert roundtripped.session_id == original.session_id
      assert roundtripped.sequence == original.sequence
      assert roundtripped.payload["decision"]["type"] == "block"
      assert roundtripped.payload["decision"]["reason"] == "unsafe"
      assert roundtripped.payload["context_summary"]["active_task"] == "T1"
      assert roundtripped.payload["context_summary"]["session_age"] == 100
    end
  end
end
