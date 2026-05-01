defmodule Tet.Subagent.SpecTest do
  use ExUnit.Case, async: true

  alias Tet.Subagent.Spec

  describe "new/1" do
    test "builds a valid spec with required attrs" do
      assert {:ok, %Spec{} = spec} =
               Spec.new(%{profile_id: "coder", parent_task_id: "task_abc123"})

      assert spec.profile_id == "coder"
      assert spec.parent_task_id == "task_abc123"
      assert spec.model == nil
      assert spec.tool_allowlist == nil
      assert spec.budget == nil
      assert spec.timeout == nil
    end

    test "accepts string keys" do
      assert {:ok, %Spec{} = spec} =
               Spec.new(%{"profile_id" => "architect", "parent_task_id" => "task_def456"})

      assert spec.profile_id == "architect"
      assert spec.parent_task_id == "task_def456"
    end

    test "accepts optional fields" do
      attrs = %{
        profile_id: "reviewer",
        parent_task_id: "task_ghi789",
        model: "gpt-4o",
        tool_allowlist: ["read", "search"],
        budget: 500_000,
        timeout: 30_000
      }

      assert {:ok, %Spec{} = spec} = Spec.new(attrs)
      assert spec.model == "gpt-4o"
      assert spec.tool_allowlist == ["read", "search"]
      assert spec.budget == 500_000
      assert spec.timeout == 30_000
    end

    test "accepts empty tool_allowlist as nil" do
      assert {:ok, %Spec{} = spec} =
               Spec.new(%{
                 profile_id: "coder",
                 parent_task_id: "task_123",
                 tool_allowlist: []
               })

      assert spec.tool_allowlist == nil
    end

    test "rejects missing profile_id" do
      assert {:error, {:invalid_entity_field, :subagent_spec, :profile_id}} =
               Spec.new(%{parent_task_id: "task_123"})
    end

    test "rejects missing parent_task_id" do
      assert {:error, {:invalid_entity_field, :subagent_spec, :parent_task_id}} =
               Spec.new(%{profile_id: "coder"})
    end

    test "rejects empty profile_id" do
      assert {:error, {:invalid_entity_field, :subagent_spec, :profile_id}} =
               Spec.new(%{profile_id: "", parent_task_id: "task_123"})
    end

    test "rejects non-list tool_allowlist" do
      assert {:error, {:invalid_entity_field, :subagent_spec, :tool_allowlist}} =
               Spec.new(%{
                 profile_id: "coder",
                 parent_task_id: "task_123",
                 tool_allowlist: "not_a_list"
               })
    end

    test "rejects non-positive budget" do
      assert {:error, {:invalid_entity_field, :subagent_spec, :budget}} =
               Spec.new(%{
                 profile_id: "coder",
                 parent_task_id: "task_123",
                 budget: 0
               })
    end

    test "rejects non-integer timeout" do
      assert {:error, {:invalid_entity_field, :subagent_spec, :timeout}} =
               Spec.new(%{
                 profile_id: "coder",
                 parent_task_id: "task_123",
                 timeout: "thirty_seconds"
               })
    end
  end

  describe "new!/1" do
    test "raises on invalid attrs" do
      assert_raise ArgumentError, ~r/invalid subagent spec/, fn ->
        Spec.new!(%{profile_id: ""})
      end
    end

    test "returns spec on valid attrs" do
      spec = Spec.new!(%{profile_id: "coder", parent_task_id: "task_123"})
      assert %Spec{} = spec
      assert spec.profile_id == "coder"
    end
  end

  describe "to_map/1" do
    test "converts spec to map" do
      spec = Spec.new!(%{profile_id: "coder", parent_task_id: "task_abc", model: "gpt-4o"})
      map = Spec.to_map(spec)

      assert map.profile_id == "coder"
      assert map.parent_task_id == "task_abc"
      assert map.model == "gpt-4o"
      assert map.budget == nil
    end
  end

  describe "from_map/1" do
    test "round-trips through to_map" do
      original = Spec.new!(%{profile_id: "coder", parent_task_id: "task_abc", model: "gpt-4o"})
      map = Spec.to_map(original)
      assert {:ok, restored} = Spec.from_map(map)
      assert restored.profile_id == original.profile_id
      assert restored.parent_task_id == original.parent_task_id
      assert restored.model == original.model
    end
  end

  describe "subagent_id/1" do
    test "generates deterministic id from parent task" do
      spec = Spec.new!(%{profile_id: "coder", parent_task_id: "task_xyz789"})
      assert Spec.subagent_id(spec) == "sub_task_xyz789"
    end
  end
end
