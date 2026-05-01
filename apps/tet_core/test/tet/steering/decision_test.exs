defmodule Tet.Steering.DecisionTest do
  use ExUnit.Case, async: true

  alias Tet.Steering.Decision

  describe "new/1" do
    test "creates a :continue decision with defaults" do
      assert {:ok, decision} = Decision.new(%{type: :continue})
      assert decision.type == :continue
      assert decision.reason == nil
      assert decision.confidence == 1.0
      assert decision.context == %{}
      assert decision.guidance_message == nil
    end

    test "creates a :focus decision with guidance_message" do
      assert {:ok, decision} =
               Decision.new(%{
                 type: :focus,
                 reason: "narrowing to auth module",
                 confidence: 0.85,
                 context: %{active_task: "T1"},
                 guidance_message: "Focus on the authentication module."
               })

      assert decision.type == :focus
      assert decision.reason == "narrowing to auth module"
      assert decision.confidence == 0.85
      assert decision.context == %{active_task: "T1"}
      assert decision.guidance_message == "Focus on the authentication module."
    end

    test "creates a :guide decision with guidance_message" do
      assert {:ok, decision} =
               Decision.new(%{
                 type: :guide,
                 guidance_message: "Consider reviewing the API contract first."
               })

      assert decision.type == :guide
      assert decision.guidance_message == "Consider reviewing the API contract first."
    end

    test "creates a :block decision with reason" do
      assert {:ok, decision} =
               Decision.new(%{
                 type: :block,
                 reason: "unsafe operation without approval",
                 confidence: 0.99
               })

      assert decision.type == :block
      assert decision.reason == "unsafe operation without approval"
      assert decision.confidence == 0.99
    end

    test "accepts string type and normalizes to atom" do
      assert {:ok, decision} = Decision.new(%{type: "continue"})
      assert decision.type == :continue

      assert {:ok, decision} = Decision.new(%{type: "block", reason: "test"})
      assert decision.type == :block
    end

    test "accepts string guidance_message for :guide and :focus" do
      assert {:ok, %Decision{type: :guide, guidance_message: "msg"}} =
               Decision.new(%{type: "guide", guidance_message: "msg"})

      assert {:ok, %Decision{type: :focus, guidance_message: "msg"}} =
               Decision.new(%{type: "focus", guidance_message: "msg"})
    end
  end

  describe "new/1 validation" do
    test "rejects invalid type" do
      assert {:error, {:invalid_steering_type, :frobnicate}} =
               Decision.new(%{type: :frobnicate})
    end

    test "rejects invalid string type" do
      assert {:error, {:invalid_steering_type, "frobnicate"}} =
               Decision.new(%{type: "frobnicate"})
    end

    test "rejects missing type" do
      assert {:error, {:invalid_steering_type, nil}} = Decision.new(%{})
    end

    test "rejects confidence below 0.0" do
      assert {:error, {:invalid_confidence, -0.1}} =
               Decision.new(%{type: :continue, confidence: -0.1})
    end

    test "rejects confidence above 1.0" do
      assert {:error, {:invalid_confidence, 1.5}} =
               Decision.new(%{type: :continue, confidence: 1.5})
    end

    test "accepts confidence at boundaries" do
      assert {:ok, %Decision{confidence: 0.0}} =
               Decision.new(%{type: :continue, confidence: 0.0})

      assert {:ok, %Decision{confidence: 1.0}} =
               Decision.new(%{type: :continue, confidence: 1.0})
    end

    test "accepts integer confidence (0 or 1)" do
      assert {:ok, %Decision{confidence: 0.0}} =
               Decision.new(%{type: :continue, confidence: 0})

      assert {:ok, %Decision{confidence: 1.0}} =
               Decision.new(%{type: :continue, confidence: 1})
    end

    test "rejects integer confidence outside range" do
      assert {:error, {:invalid_confidence, -1}} =
               Decision.new(%{type: :continue, confidence: -1})

      assert {:error, {:invalid_confidence, 2}} =
               Decision.new(%{type: :continue, confidence: 2})
    end

    test "rejects :focus without guidance_message" do
      assert {:error, {:guidance_message_required, :focus}} =
               Decision.new(%{type: :focus})
    end

    test "rejects :focus with empty guidance_message" do
      assert {:error, {:guidance_message_required, :focus}} =
               Decision.new(%{type: :focus, guidance_message: ""})
    end

    test "rejects :guide without guidance_message" do
      assert {:error, {:guidance_message_required, :guide}} =
               Decision.new(%{type: :guide})
    end

    test "allows :continue without guidance_message" do
      assert {:ok, %Decision{type: :continue}} = Decision.new(%{type: :continue})
    end

    test "allows :block without guidance_message" do
      assert {:ok, %Decision{type: :block, reason: "nope"}} =
               Decision.new(%{type: :block, reason: "nope"})
    end

    test "rejects non-map context" do
      assert {:error, {:invalid_decision_field, :context}} =
               Decision.new(%{type: :continue, context: "not a map"})
    end

    test "rejects non-binary reason" do
      assert {:error, {:invalid_decision_field, :reason}} =
               Decision.new(%{type: :continue, reason: 42})
    end

    test "rejects non-binary guidance_message" do
      assert {:error, {:invalid_decision_field, :guidance_message}} =
               Decision.new(%{type: :guide, guidance_message: 42})
    end
  end

  describe "new!/1" do
    test "builds decision or raises" do
      decision = Decision.new!(%{type: :continue})
      assert decision.type == :continue

      assert_raise ArgumentError, ~r/invalid steering decision/, fn ->
        Decision.new!(%{type: :frobnicate})
      end
    end
  end

  describe "type query helpers" do
    test "continue?/1" do
      assert Decision.continue?(Decision.new!(%{type: :continue}))
      refute Decision.continue?(Decision.new!(%{type: :block, reason: "nope"}))
    end

    test "focus?/1" do
      assert Decision.focus?(Decision.new!(%{type: :focus, guidance_message: "focus!"}))
      refute Decision.focus?(Decision.new!(%{type: :continue}))
    end

    test "guide?/1" do
      assert Decision.guide?(Decision.new!(%{type: :guide, guidance_message: "guide!"}))
      refute Decision.guide?(Decision.new!(%{type: :continue}))
    end

    test "block?/1" do
      assert Decision.block?(Decision.new!(%{type: :block, reason: "nope"}))
      refute Decision.block?(Decision.new!(%{type: :continue}))
    end

    test "has_guidance?/1" do
      assert Decision.has_guidance?(Decision.new!(%{type: :focus, guidance_message: "focus!"}))
      assert Decision.has_guidance?(Decision.new!(%{type: :guide, guidance_message: "guide!"}))
      refute Decision.has_guidance?(Decision.new!(%{type: :continue}))
      refute Decision.has_guidance?(Decision.new!(%{type: :block, reason: "nope"}))
    end
  end

  describe "types/0 and guidance_types/0" do
    test "types/0 returns all decision types" do
      assert Decision.types() == [:continue, :focus, :guide, :block]
    end

    test "guidance_types/0 returns types that carry guidance" do
      assert Decision.guidance_types() == [:focus, :guide]
    end
  end

  describe "to_map/1 and from_map/1" do
    test "round-trips a :continue decision" do
      original = Decision.new!(%{type: :continue})
      mapped = Decision.to_map(original)

      assert mapped.type == "continue"
      assert mapped.reason == nil
      assert mapped.confidence == 1.0
      assert mapped.context == %{}
      assert mapped.guidance_message == nil

      assert {:ok, roundtripped} = Decision.from_map(mapped)
      assert roundtripped.type == original.type
      assert roundtripped.confidence == original.confidence
    end

    test "round-trips a :block decision with context" do
      original =
        Decision.new!(%{
          type: :block,
          reason: "unsafe operation",
          confidence: 0.95,
          context: %{active_task: "T1", tool: "write"},
          guidance_message: nil
        })

      mapped = Decision.to_map(original)

      assert mapped.type == "block"
      assert mapped.reason == "unsafe operation"
      assert mapped.confidence == 0.95
      # Context keys stringified for JSON
      assert mapped.context["active_task"] == "T1"
      assert mapped.context["tool"] == "write"

      assert {:ok, roundtripped} = Decision.from_map(mapped)
      assert roundtripped.type == :block
      assert roundtripped.reason == "unsafe operation"
      assert roundtripped.confidence == 0.95
    end

    test "round-trips a :guide decision with guidance_message" do
      original =
        Decision.new!(%{
          type: :guide,
          guidance_message: "Consider reviewing the API contract first.",
          confidence: 0.7
        })

      mapped = Decision.to_map(original)
      assert mapped.type == "guide"
      assert mapped.guidance_message == "Consider reviewing the API contract first."
      assert mapped.confidence == 0.7

      assert {:ok, roundtripped} = Decision.from_map(mapped)
      assert roundtripped.type == :guide
      assert roundtripped.guidance_message == "Consider reviewing the API contract first."
    end

    test "round-trips with string keys in attrs" do
      mapped = %{
        "type" => "continue",
        "reason" => nil,
        "confidence" => 0.9,
        "context" => %{},
        "guidance_message" => nil
      }

      assert {:ok, decision} = Decision.from_map(mapped)
      assert decision.type == :continue
      assert decision.confidence == 0.9
    end

    test "atom keys in context get stringified in to_map" do
      decision =
        Decision.new!(%{
          type: :guide,
          guidance_message: "test",
          context: %{task_id: :t1, priority: "high"}
        })

      mapped = Decision.to_map(decision)
      assert mapped.context["task_id"] == "t1"
      assert mapped.context["priority"] == "high"
    end
  end

  describe "from_map/1 validation" do
    test "rejects invalid type in map" do
      assert {:error, {:invalid_steering_type, "frobnicate"}} =
               Decision.from_map(%{
                 "type" => "frobnicate",
                 "confidence" => 1.0,
                 "context" => %{},
                 "reason" => nil,
                 "guidance_message" => nil
               })
    end

    test "rejects missing guidance_message for :guide in map" do
      assert {:error, {:guidance_message_required, :guide}} =
               Decision.from_map(%{
                 "type" => "guide",
                 "confidence" => 1.0,
                 "context" => %{},
                 "reason" => nil,
                 "guidance_message" => nil
               })
    end
  end
end
