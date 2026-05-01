defmodule Tet.SteeringTest do
  use ExUnit.Case, async: true

  alias Tet.Steering

  describe "decision types" do
    test "decision_types/0 returns all types" do
      assert Steering.decision_types() == [:continue, :focus, :guide, :block]
    end

    test "guidance_types/0 returns guidance-carrying types" do
      assert Steering.guidance_types() == [:focus, :guide]
    end
  end

  describe "new_decision/1" do
    test "creates a continue decision" do
      assert {:ok, decision} = Steering.new_decision(%{type: :continue})
      assert decision.type == :continue
      assert Steering.continue?(decision)
    end

    test "creates a focus decision" do
      assert {:ok, decision} =
               Steering.new_decision(%{type: :focus, guidance_message: "focus!"})

      assert decision.type == :focus
      assert Steering.focus?(decision)
      assert Steering.has_guidance?(decision)
    end

    test "creates a guide decision" do
      assert {:ok, decision} =
               Steering.new_decision(%{type: :guide, guidance_message: "guide!"})

      assert decision.type == :guide
      assert Steering.guide?(decision)
      assert Steering.has_guidance?(decision)
    end

    test "creates a block decision" do
      assert {:ok, decision} =
               Steering.new_decision(%{type: :block, reason: "nope"})

      assert decision.type == :block
      assert Steering.block?(decision)
      refute Steering.has_guidance?(decision)
    end
  end

  describe "new_decision!/1" do
    test "builds or raises" do
      decision = Steering.new_decision!(%{type: :continue})
      assert Steering.continue?(decision)

      assert_raise ArgumentError, fn ->
        Steering.new_decision!(%{type: :invalid})
      end
    end
  end

  describe "new_context/1" do
    test "creates context from attrs" do
      assert {:ok, ctx} = Steering.new_context(%{session_age: 10})
      assert ctx.session_age == 10
    end

    test "rejects invalid context" do
      assert {:error, _} = Steering.new_context(%{})
    end
  end

  describe "new_context!/1" do
    test "builds or raises" do
      ctx = Steering.new_context!(%{session_age: 5})
      assert ctx.session_age == 5

      assert_raise ArgumentError, fn ->
        Steering.new_context!(%{})
      end
    end
  end

  describe "serialization delegates" do
    test "decision_to_map/1 and decision_from_map/1" do
      decision = Steering.new_decision!(%{type: :block, reason: "test"})
      mapped = Steering.decision_to_map(decision)
      assert mapped.type == "block"

      assert {:ok, roundtripped} = Steering.decision_from_map(mapped)
      assert roundtripped.type == :block
      assert roundtripped.reason == "test"
    end

    test "context_to_map/1 and context_from_map/1" do
      ctx = Steering.new_context!(%{session_age: 42})
      mapped = Steering.context_to_map(ctx)
      assert mapped.session_age == 42

      assert {:ok, roundtripped} = Steering.context_from_map(mapped)
      assert roundtripped.session_age == 42
    end
  end
end
