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
