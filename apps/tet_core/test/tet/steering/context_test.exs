defmodule Tet.Steering.ContextTest do
  use ExUnit.Case, async: true

  alias Tet.Steering.Context

  describe "new/1" do
    test "creates a context with required session_age only" do
      assert {:ok, ctx} = Context.new(%{session_age: 0})
      assert ctx.session_age == 0
      assert ctx.recent_events == []
      assert ctx.active_task == nil
      assert ctx.task_progress == %{}
      assert ctx.tool_usage_summary == %{}
    end

    test "creates a context with all fields" do
      assert {:ok, ctx} =
               Context.new(%{
                 session_age: 42,
                 recent_events: [%{type: :tool_call, tool: "read"}],
                 active_task: %{id: "T1", title: "Research auth", category: :researching},
                 task_progress: %{completed: 2, total: 5},
                 tool_usage_summary: %{read: 10, list: 3, search: 1}
               })

      assert ctx.session_age == 42
      assert ctx.recent_events == [%{type: :tool_call, tool: "read"}]
      assert ctx.active_task == %{id: "T1", title: "Research auth", category: :researching}
      assert ctx.task_progress == %{completed: 2, total: 5}
      assert ctx.tool_usage_summary == %{read: 10, list: 3, search: 1}
    end

    test "accepts string keys" do
      assert {:ok, ctx} = Context.new(%{"session_age" => 10})
      assert ctx.session_age == 10
    end
  end

  describe "new/1 validation" do
    test "rejects missing session_age" do
      assert {:error, {:invalid_context_field, :session_age}} = Context.new(%{})
    end

    test "rejects negative session_age" do
      assert {:error, {:invalid_context_field, :session_age}} = Context.new(%{session_age: -1})
    end

    test "accepts float session_age (truncated)" do
      assert {:ok, ctx} = Context.new(%{session_age: 42.7})
      assert ctx.session_age == 42
    end

    test "rejects non-integer session_age" do
      assert {:error, {:invalid_context_field, :session_age}} =
               Context.new(%{session_age: "not a number"})
    end

    test "rejects non-list recent_events" do
      assert {:error, {:invalid_context_field, :recent_events}} =
               Context.new(%{session_age: 0, recent_events: "not a list"})
    end

    test "rejects non-map task_progress" do
      assert {:error, {:invalid_context_field, :task_progress}} =
               Context.new(%{session_age: 0, task_progress: "not a map"})
    end

    test "rejects non-map tool_usage_summary" do
      assert {:error, {:invalid_context_field, :tool_usage_summary}} =
               Context.new(%{session_age: 0, tool_usage_summary: "not a map"})
    end

    test "rejects non-map active_task" do
      assert {:error, {:invalid_context_field, :active_task}} =
               Context.new(%{session_age: 0, active_task: "not a map"})
    end
  end

  describe "new!/1" do
    test "builds context or raises" do
      ctx = Context.new!(%{session_age: 0})
      assert ctx.session_age == 0

      assert_raise ArgumentError, ~r/invalid steering context/, fn ->
        Context.new!(%{})
      end
    end
  end

  describe "to_map/1 and from_map/1" do
    test "round-trips a minimal context" do
      original = Context.new!(%{session_age: 0})
      mapped = Context.to_map(original)

      assert mapped.session_age == 0
      assert mapped.recent_events == []
      assert mapped.active_task == nil
      assert mapped.task_progress == %{}
      assert mapped.tool_usage_summary == %{}

      assert {:ok, roundtripped} = Context.from_map(mapped)
      assert roundtripped.session_age == original.session_age
    end

    test "round-trips a fully populated context" do
      original =
        Context.new!(%{
          session_age: 99,
          recent_events: [%{type: :tool_call}],
          active_task: %{id: "T1", title: "Test"},
          task_progress: %{done: 3, total: 10},
          tool_usage_summary: %{reads: 5}
        })

      mapped = Context.to_map(original)
      assert mapped.session_age == 99
      assert mapped.recent_events == [%{type: :tool_call}]
      assert mapped.active_task == %{id: "T1", title: "Test"}
      assert mapped.task_progress == %{done: 3, total: 10}
      assert mapped.tool_usage_summary == %{reads: 5}

      assert {:ok, roundtripped} = Context.from_map(mapped)
      assert roundtripped.session_age == 99
      # recent_events and active_task keep atom keys through round-trip
      # since Context.to_map/from_map is a pass-through for nested values
      assert roundtripped.recent_events == [%{type: :tool_call}]
      assert roundtripped.active_task.id == "T1"
      assert roundtripped.active_task.title == "Test"
    end

    test "round-trips with string keys" do
      mapped = %{
        "session_age" => 30,
        "recent_events" => [],
        "active_task" => nil,
        "task_progress" => %{},
        "tool_usage_summary" => %{}
      }

      assert {:ok, ctx} = Context.from_map(mapped)
      assert ctx.session_age == 30
    end

    test "rejects invalid context from_map" do
      assert {:error, {:invalid_context_field, :session_age}} =
               Context.from_map(%{
                 "session_age" => "invalid",
                 "recent_events" => [],
                 "active_task" => nil,
                 "task_progress" => %{},
                 "tool_usage_summary" => %{}
               })
    end
  end
end
