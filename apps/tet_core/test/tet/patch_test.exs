defmodule Tet.PatchTest do
  use ExUnit.Case, async: true

  alias Tet.Patch

  describe "propose/1" do
    test "accepts valid patch with create operations" do
      attrs = %{
        operations: [
          %{kind: :create, file_path: "lib/new.ex", content: "defmodule New do\nend\n"}
        ],
        workspace_path: "/workspace"
      }

      assert {:ok, patch} = Patch.propose(attrs)
      assert length(patch.operations) == 1
      assert patch.workspace_path == "/workspace"
    end

    test "accepts valid patch with mixed operations" do
      attrs = %{
        operations: [
          %{kind: :create, file_path: "lib/a.ex", content: "module A"},
          %{kind: :modify, file_path: "lib/b.ex", old_str: "foo", new_str: "bar"},
          %{kind: :delete, file_path: "lib/c.ex"}
        ],
        workspace_path: "/workspace",
        tool_call_id: "call_123",
        task_id: "task_1",
        approval_id: "appr_1"
      }

      assert {:ok, patch} = Patch.propose(attrs)
      assert length(patch.operations) == 3
      assert patch.tool_call_id == "call_123"
      assert patch.task_id == "task_1"
      assert patch.approval_id == "appr_1"
    end

    test "accepts string keys" do
      assert {:ok, patch} =
               Patch.propose(%{
                 "operations" => [
                   %{"kind" => "create", "file_path" => "lib/new.ex", "content" => "data"}
                 ],
                 "workspace_path" => "/workspace"
               })

      assert length(patch.operations) == 1
    end

    test "rejects missing operations" do
      assert {:error, {:invalid_patch, :missing_operations}} =
               Patch.propose(%{workspace_path: "/workspace"})
    end

    test "rejects empty operations" do
      assert {:error, {:invalid_patch, :empty_operations}} =
               Patch.propose(%{operations: [], workspace_path: "/workspace"})
    end

    test "rejects missing workspace_path" do
      assert {:error, {:invalid_patch, :workspace_path_required}} =
               Patch.propose(%{operations: [%{kind: :create, file_path: "f.ex", content: "x"}]})
    end

    test "rejects invalid operation" do
      assert {:error, {:invalid_operation_kind, _}} =
               Patch.propose(%{
                 operations: [%{kind: :bad, file_path: "f.ex"}],
                 workspace_path: "/workspace"
               })
    end

    test "accepts optional expected_result_hash" do
      hash = String.duplicate("a", 64)

      assert {:ok, patch} =
               Patch.propose(%{
                 operations: [%{kind: :create, file_path: "f.ex", content: "x"}],
                 workspace_path: "/workspace",
                 expected_result_hash: hash
               })

      assert patch.expected_result_hash == hash
    end

    test "rejects invalid hash length" do
      assert {:error, {:invalid_patch, :invalid_hash_length, _}} =
               Patch.propose(%{
                 operations: [%{kind: :create, file_path: "f.ex", content: "x"}],
                 workspace_path: "/workspace",
                 expected_result_hash: "too-short"
               })
    end
  end

  describe "propose!/1" do
    test "creates or raises" do
      patch =
        Patch.propose!(%{
          operations: [%{kind: :create, file_path: "f.ex", content: "x"}],
          workspace_path: "/workspace"
        })

      assert length(patch.operations) == 1

      assert_raise ArgumentError, fn ->
        Patch.propose!(%{operations: [], workspace_path: "/workspace"})
      end
    end
  end

  describe "affected_paths/1" do
    test "returns all paths from operations" do
      patch =
        Patch.propose!(%{
          operations: [
            %{kind: :create, file_path: "lib/a.ex", content: "x"},
            %{kind: :modify, file_path: "lib/b.ex", old_str: "a", new_str: "b"},
            %{kind: :delete, file_path: "lib/c.ex"}
          ],
          workspace_path: "/workspace"
        })

      assert Patch.affected_paths(patch) == ["lib/a.ex", "lib/b.ex", "lib/c.ex"]
    end
  end

  describe "created_paths/1" do
    test "returns only create paths" do
      patch =
        Patch.propose!(%{
          operations: [
            %{kind: :create, file_path: "lib/a.ex", content: "x"},
            %{kind: :modify, file_path: "lib/b.ex", old_str: "a", new_str: "b"}
          ],
          workspace_path: "/workspace"
        })

      assert Patch.created_paths(patch) == ["lib/a.ex"]
    end
  end

  describe "modified_paths/1" do
    test "returns only modify paths" do
      patch =
        Patch.propose!(%{
          operations: [
            %{kind: :create, file_path: "lib/a.ex", content: "x"},
            %{kind: :modify, file_path: "lib/b.ex", old_str: "a", new_str: "b"}
          ],
          workspace_path: "/workspace"
        })

      assert Patch.modified_paths(patch) == ["lib/b.ex"]
    end
  end

  describe "deleted_paths/1" do
    test "returns only delete paths" do
      patch =
        Patch.propose!(%{
          operations: [
            %{kind: :create, file_path: "lib/a.ex", content: "x"},
            %{kind: :delete, file_path: "lib/b.ex"}
          ],
          workspace_path: "/workspace"
        })

      assert Patch.deleted_paths(patch) == ["lib/b.ex"]
    end
  end

  describe "summary/1" do
    test "returns summary map" do
      patch =
        Patch.propose!(%{
          operations: [
            %{kind: :create, file_path: "lib/a.ex", content: "x"},
            %{kind: :modify, file_path: "lib/b.ex", old_str: "a", new_str: "b"},
            %{kind: :delete, file_path: "lib/c.ex"}
          ],
          workspace_path: "/workspace"
        })

      summary = Patch.summary(patch)
      assert summary.total_operations == 3
      assert summary.creates == 1
      assert summary.modifies == 1
      assert summary.deletes == 1
      assert summary.affected_files == ["lib/a.ex", "lib/b.ex", "lib/c.ex"]
    end
  end

  describe "to_map/1" do
    test "converts to JSON-friendly map" do
      patch =
        Patch.propose!(%{
          operations: [%{kind: :create, file_path: "f.ex", content: "x"}],
          workspace_path: "/workspace",
          tool_call_id: "call_1"
        })

      map = Patch.to_map(patch)
      assert is_list(map["operations"])
      assert map["workspace_path"] == "/workspace"
      assert map["tool_call_id"] == "call_1"
      refute Map.has_key?(map, "expected_result_hash")
    end
  end
end
