defmodule Tet.HookManager.HookTest do
  use ExUnit.Case, async: true

  alias Tet.HookManager.Hook

  describe "new/1" do
    test "builds a valid hook with atom keys" do
      assert {:ok, hook} =
               Hook.new(%{
                 id: "audit-1",
                 event_type: :pre,
                 priority: 100,
                 action_fn: fn ctx -> {:continue, ctx} end,
                 description: "Audit log"
               })

      assert hook.id == "audit-1"
      assert hook.event_type == :pre
      assert hook.priority == 100
      assert hook.description == "Audit log"
    end

    test "builds a valid hook with string keys" do
      assert {:ok, hook} =
               Hook.new(%{
                 "id" => "test-1",
                 "event_type" => "post",
                 "priority" => 50,
                 "action_fn" => fn ctx -> {:continue, ctx} end
               })

      assert hook.id == "test-1"
      assert hook.event_type == :post
      assert hook.priority == 50
    end

    test "accepts :pre_tool_use as event_type (normalizes to :pre)" do
      assert {:ok, hook} =
               Hook.new(%{
                 id: "pre-tool",
                 event_type: :pre_tool_use,
                 priority: 0,
                 action_fn: fn ctx -> {:continue, ctx} end
               })

      assert hook.event_type == :pre
    end

    test "accepts :post_tool_use as event_type (normalizes to :post)" do
      assert {:ok, hook} =
               Hook.new(%{
                 id: "post-tool",
                 event_type: :post_tool_use,
                 priority: 0,
                 action_fn: fn ctx -> {:continue, ctx} end
               })

      assert hook.event_type == :post
    end

    test "rejects missing id" do
      assert {:error, :invalid_hook_id} =
               Hook.new(%{
                 event_type: :pre,
                 priority: 0,
                 action_fn: fn ctx -> {:continue, ctx} end
               })
    end

    test "rejects empty id" do
      assert {:error, :invalid_hook_id} =
               Hook.new(%{
                 id: "",
                 event_type: :pre,
                 priority: 0,
                 action_fn: fn ctx -> {:continue, ctx} end
               })
    end

    test "rejects invalid event_type" do
      assert {:error, :invalid_event_type} =
               Hook.new(%{
                 id: "bad",
                 event_type: :unknown,
                 priority: 0,
                 action_fn: fn ctx -> {:continue, ctx} end
               })
    end

    test "rejects non-integer priority" do
      assert {:error, :invalid_priority} =
               Hook.new(%{
                 id: "bad",
                 event_type: :pre,
                 priority: "high",
                 action_fn: fn ctx -> {:continue, ctx} end
               })
    end

    test "rejects missing action_fn" do
      assert {:error, :invalid_action_fn} =
               Hook.new(%{
                 id: "bad",
                 event_type: :pre,
                 priority: 0
               })
    end

    test "rejects non-function action_fn" do
      assert {:error, :invalid_action_fn} =
               Hook.new(%{
                 id: "bad",
                 event_type: :pre,
                 priority: 0,
                 action_fn: "not_a_fun"
               })
    end

    test "description is optional" do
      assert {:ok, hook} =
               Hook.new(%{
                 id: "no-desc",
                 event_type: :pre,
                 priority: 0,
                 action_fn: fn ctx -> {:continue, ctx} end
               })

      assert hook.description == nil
    end

    test "empty string description becomes nil" do
      assert {:ok, hook} =
               Hook.new(%{
                 id: "empty-desc",
                 event_type: :pre,
                 priority: 0,
                 action_fn: fn ctx -> {:continue, ctx} end,
                 description: ""
               })

      assert hook.description == nil
    end
  end

  describe "new!/1" do
    test "returns hook on success" do
      hook =
        Hook.new!(%{
          id: "ok",
          event_type: :pre,
          priority: 1,
          action_fn: fn ctx -> {:continue, ctx} end
        })

      assert %Hook{} = hook
    end

    test "raises on invalid attrs" do
      assert_raise ArgumentError, fn ->
        Hook.new!(%{id: "", event_type: :pre, priority: 1, action_fn: fn _ -> :block end})
      end
    end
  end

  describe "block_hook?/1" do
    test "returns true for :block" do
      assert Hook.block_hook?(:block)
    end

    test "returns false for non-block actions" do
      refute Hook.block_hook?({:continue, %{}})
      refute Hook.block_hook?({:modify, %{}})
      refute Hook.block_hook?({:guide, "msg", %{}})
    end
  end

  describe "continue_action?/1" do
    test "returns true for continue, modify, guide" do
      assert Hook.continue_action?({:continue, %{}})
      assert Hook.continue_action?({:modify, %{}})
      assert Hook.continue_action?({:guide, "msg", %{}})
    end

    test "returns false for block" do
      refute Hook.continue_action?(:block)
    end
  end

  describe "guide_action?/1" do
    test "returns true for guide actions" do
      assert Hook.guide_action?({:guide, "hello", %{}})
    end

    test "returns false for other actions" do
      refute Hook.guide_action?(:block)
      refute Hook.guide_action?({:continue, %{}})
      refute Hook.guide_action?({:modify, %{}})
    end
  end

  describe "guide_message/1" do
    test "extracts message from guide action" do
      assert Hook.guide_message({:guide, "hello world", %{}}) == "hello world"
    end

    test "returns nil for non-guide actions" do
      assert Hook.guide_message(:block) == nil
      assert Hook.guide_message({:continue, %{}}) == nil
    end
  end

  describe "action_context/1" do
    test "extracts context from continue, modify, guide" do
      ctx = %{foo: :bar}
      assert Hook.action_context({:continue, ctx}) == ctx
      assert Hook.action_context({:modify, ctx}) == ctx
      assert Hook.action_context({:guide, "msg", ctx}) == ctx
    end

    test "returns empty map for block" do
      assert Hook.action_context(:block) == %{}
    end
  end

  describe "action_types/0" do
    test "returns known action types" do
      assert :continue in Hook.action_types()
      assert :block in Hook.action_types()
      assert :modify in Hook.action_types()
      assert :guide in Hook.action_types()
    end
  end
end
