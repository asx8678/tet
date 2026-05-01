defmodule Tet.Steering.GuidanceMessageTest do
  use ExUnit.Case, async: true

  alias Tet.Steering.GuidanceMessage

  describe "new/1" do
    test "creates a guidance message with required fields" do
      assert {:ok, msg} =
               GuidanceMessage.new(%{
                 decision_type: :focus,
                 message: "Focus on the auth module."
               })

      assert msg.decision_type == :focus
      assert msg.message == "Focus on the auth module."
      assert msg.expired == false
      assert is_binary(msg.id)
      assert is_struct(msg.created_at, DateTime)
    end

    test "creates a guide decision" do
      assert {:ok, msg} =
               GuidanceMessage.new(%{
                 decision_type: :guide,
                 message: "Consider reviewing the API contract first."
               })

      assert msg.decision_type == :guide
      assert msg.message == "Consider reviewing the API contract first."
    end

    test "accepts explicit id, session_id, and event_seq" do
      assert {:ok, msg} =
               GuidanceMessage.new(%{
                 id: "guid-1",
                 session_id: "ses_123",
                 event_seq: 42,
                 decision_type: :focus,
                 message: "Stay focused!"
               })

      assert msg.id == "guid-1"
      assert msg.session_id == "ses_123"
      assert msg.event_seq == 42
    end

    test "accepts trigger_event_type and trigger_event_seq" do
      assert {:ok, msg} =
               GuidanceMessage.new(%{
                 decision_type: :guide,
                 message: "Check the logs.",
                 trigger_event_type: :"tool.finished",
                 trigger_event_seq: 7
               })

      assert msg.trigger_event_type == :"tool.finished"
      assert msg.trigger_event_seq == 7
    end

    test "accepts expired and created_at overrides" do
      dt = DateTime.utc_now()

      assert {:ok, msg} =
               GuidanceMessage.new(%{
                 decision_type: :guide,
                 message: "Done.",
                 expired: true,
                 created_at: dt
               })

      assert msg.expired == true
      assert msg.created_at == dt
    end

    test "accepts string decision_type and normalizes to atom" do
      assert {:ok, msg} = GuidanceMessage.new(%{decision_type: "focus", message: "Hi"})
      assert msg.decision_type == :focus

      assert {:ok, msg} = GuidanceMessage.new(%{decision_type: "guide", message: "Hi"})
      assert msg.decision_type == :guide
    end

    test "rejects missing message" do
      assert {:error, :guidance_message_required} =
               GuidanceMessage.new(%{decision_type: :focus})

      assert {:error, :guidance_message_required} =
               GuidanceMessage.new(%{decision_type: :focus, message: ""})
    end

    test "rejects invalid decision_type" do
      assert {:error, {:invalid_decision_type, :block}} =
               GuidanceMessage.new(%{decision_type: :block, message: "nope"})

      assert {:error, {:invalid_decision_type, _}} =
               GuidanceMessage.new(%{decision_type: :invalid, message: "nope"})
    end
  end

  describe "new!/1" do
    test "builds or raises" do
      msg = GuidanceMessage.new!(%{decision_type: :guide, message: "Hello"})
      assert msg.message == "Hello"

      assert_raise ArgumentError, fn ->
        GuidanceMessage.new!(%{decision_type: :focus})
      end
    end
  end

  describe "from_decision/2" do
    test "builds a guidance message from a steering decision" do
      decision =
        Tet.Steering.new_decision!(%{
          type: :focus,
          guidance_message: "Focus on auth.",
          reason: "narrowing scope"
        })

      assert {:ok, msg} =
               GuidanceMessage.from_decision(decision,
                 session_id: "ses_1",
                 event_seq: 5,
                 trigger_event_type: :"tool.started",
                 trigger_event_seq: 5
               )

      assert msg.decision_type == :focus
      assert msg.message == "Focus on auth."
      assert msg.session_id == "ses_1"
      assert msg.event_seq == 5
      assert msg.trigger_event_type == :"tool.started"
      assert msg.trigger_event_seq == 5
    end

    test "requires session_id and event_seq" do
      decision = Tet.Steering.new_decision!(%{type: :guide, guidance_message: "Hi"})

      assert_raise KeyError, fn ->
        GuidanceMessage.from_decision(decision, session_id: "ses_1")
      end
    end
  end

  describe "expire/1" do
    test "marks a message as expired" do
      msg = GuidanceMessage.new!(%{decision_type: :guide, message: "Hello"})
      refute msg.expired

      expired = GuidanceMessage.expire(msg)
      assert expired.expired == true
      assert expired.id == msg.id
    end
  end

  describe "active?/1" do
    test "returns true for non-expired messages" do
      msg = GuidanceMessage.new!(%{decision_type: :guide, message: "Hi"})
      assert GuidanceMessage.active?(msg)
    end

    test "returns false for expired messages" do
      msg = GuidanceMessage.new!(%{decision_type: :guide, message: "Hi", expired: true})
      refute GuidanceMessage.active?(msg)
    end
  end

  describe "focus?/1 and guide?/1" do
    test "focus?/1 returns true for focus decisions" do
      msg = GuidanceMessage.new!(%{decision_type: :focus, message: "F"})
      assert GuidanceMessage.focus?(msg)
      refute GuidanceMessage.guide?(msg)
    end

    test "guide?/1 returns true for guide decisions" do
      msg = GuidanceMessage.new!(%{decision_type: :guide, message: "G"})
      assert GuidanceMessage.guide?(msg)
      refute GuidanceMessage.focus?(msg)
    end
  end

  describe "serialization" do
    test "to_map/1 and from_map/1 roundtrip" do
      original =
        GuidanceMessage.new!(%{
          id: "test-id",
          session_id: "ses_1",
          event_seq: 3,
          decision_type: :focus,
          message: "Focus on auth.",
          trigger_event_type: :"tool.started",
          trigger_event_seq: 3
        })

      mapped = GuidanceMessage.to_map(original)
      assert mapped.id == "test-id"
      assert mapped.session_id == "ses_1"
      assert mapped.event_seq == 3
      assert mapped.decision_type == "focus"
      assert mapped.message == "Focus on auth."
      assert mapped.trigger_event_type == "tool.started"
      assert mapped.trigger_event_seq == 3
      assert mapped.expired == false

      assert {:ok, roundtripped} = GuidanceMessage.from_map(mapped)
      assert roundtripped.id == original.id
      assert roundtripped.session_id == original.session_id
      assert roundtripped.event_seq == original.event_seq
      assert roundtripped.decision_type == original.decision_type
      assert roundtripped.message == original.message
      assert roundtripped.trigger_event_type == original.trigger_event_type
      assert roundtripped.trigger_event_seq == original.trigger_event_seq
      assert roundtripped.expired == original.expired
    end
  end
end
