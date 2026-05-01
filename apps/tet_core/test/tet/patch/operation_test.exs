defmodule Tet.Patch.OperationTest do
  use ExUnit.Case, async: true

  alias Tet.Patch.Operation

  describe "new/1" do
    test "creates a create operation with content" do
      assert {:ok, op} =
               Operation.new(%{
                 kind: :create,
                 file_path: "lib/new_file.ex",
                 content: "defmodule NewFile do\nend\n"
               })

      assert op.kind == :create
      assert op.file_path == "lib/new_file.ex"
      assert op.content == "defmodule NewFile do\nend\n"
    end

    test "creates a modify operation with content" do
      assert {:ok, op} =
               Operation.new(%{
                 kind: :modify,
                 file_path: "lib/existing.ex",
                 content: "defmodule Existing do\n  @moduledoc \"\"\nend\n"
               })

      assert op.kind == :modify
      assert op.file_path == "lib/existing.ex"
    end

    test "creates a modify operation with old_str/new_str" do
      assert {:ok, op} =
               Operation.new(%{
                 kind: :modify,
                 file_path: "lib/existing.ex",
                 old_str: "defmodule Existing do",
                 new_str: "defmodule Updated do"
               })

      assert op.kind == :modify
      assert op.old_str == "defmodule Existing do"
      assert op.new_str == "defmodule Updated do"
    end

    test "creates a modify operation with replacements list" do
      assert {:ok, op} =
               Operation.new(%{
                 kind: :modify,
                 file_path: "lib/existing.ex",
                 replacements: [%{old_str: "foo", new_str: "bar"}]
               })

      assert op.kind == :modify
      assert op.replacements == [%{old_str: "foo", new_str: "bar"}]
    end

    test "creates a delete operation" do
      assert {:ok, op} =
               Operation.new(%{
                 kind: :delete,
                 file_path: "lib/to_delete.ex"
               })

      assert op.kind == :delete
      assert op.file_path == "lib/to_delete.ex"
    end

    test "accepts string keys" do
      assert {:ok, op} =
               Operation.new(%{
                 "kind" => "create",
                 "file_path" => "lib/new.ex",
                 "content" => "content"
               })

      assert op.kind == :create
      assert op.file_path == "lib/new.ex"
    end

    test "rejects create without content" do
      assert {:error, {:invalid_operation, :create_requires_content}} =
               Operation.new(%{kind: :create, file_path: "lib/file.ex"})
    end

    test "rejects modify without content, replacements, or old_str" do
      assert {:error, {:invalid_operation, :modify_requires_content_or_replacements}} =
               Operation.new(%{kind: :modify, file_path: "lib/file.ex"})
    end

    test "rejects modify with old_str but no new_str" do
      assert {:error, {:invalid_operation, :modify_requires_new_str}} =
               Operation.new(%{
                 kind: :modify,
                 file_path: "lib/file.ex",
                 old_str: "foo"
               })
    end

    test "rejects modify with both replacements and old_str" do
      assert {:error, {:invalid_operation, :modify_with_both_replacements_and_old_str}} =
               Operation.new(%{
                 kind: :modify,
                 file_path: "lib/file.ex",
                 replacements: [%{old_str: "foo", new_str: "bar"}],
                 old_str: "baz"
               })
    end

    test "rejects delete with content" do
      assert {:error, {:invalid_operation, :delete_with_content}} =
               Operation.new(%{kind: :delete, file_path: "lib/file.ex", content: "content"})
    end

    test "rejects absolute paths" do
      assert {:error, {:invalid_operation_path, :absolute}} =
               Operation.new(%{kind: :create, file_path: "/etc/passwd", content: "data"})
    end

    test "rejects paths with traversal" do
      assert {:error, {:invalid_operation_path, :traversal}} =
               Operation.new(%{kind: :create, file_path: "../escape.ex", content: "data"})
    end

    test "rejects empty paths" do
      assert {:error, {:invalid_operation_path, :empty_or_not_string}} =
               Operation.new(%{kind: :create, file_path: "", content: "data"})
    end

    test "rejects invalid kind" do
      assert {:error, {:invalid_operation_kind, _}} =
               Operation.new(%{kind: :unknown, file_path: "lib/file.ex"})
    end

    test "accepts optional expected_hash" do
      hash = String.duplicate("a", 64)

      assert {:ok, op} =
               Operation.new(%{
                 kind: :modify,
                 file_path: "lib/file.ex",
                 old_str: "foo",
                 new_str: "bar",
                 expected_hash: hash
               })

      assert op.expected_hash == hash
    end

    test "rejects expected_hash that is not 64-char hex" do
      assert {:error, {:invalid_operation, :invalid_expected_hash}} =
               Operation.new(%{
                 kind: :modify,
                 file_path: "lib/file.ex",
                 old_str: "foo",
                 new_str: "bar",
                 expected_hash: "short"
               })

      assert {:error, {:invalid_operation, :invalid_expected_hash}} =
               Operation.new(%{
                 kind: :modify,
                 file_path: "lib/file.ex",
                 old_str: "foo",
                 new_str: "bar",
                 expected_hash: "nothex!" |> String.pad_trailing(64, "0")
               })

      assert {:error, {:invalid_operation, :invalid_expected_hash}} =
               Operation.new(%{
                 kind: :modify,
                 file_path: "lib/file.ex",
                 old_str: "foo",
                 new_str: "bar",
                 expected_hash: 12345
               })

      assert {:error, {:invalid_operation, :invalid_expected_hash}} =
               Operation.new(%{
                 kind: :delete,
                 file_path: "lib/file.ex",
                 expected_hash: "ggg"
               })
    end

    test "rejects expected_hash on create with invalid format" do
      assert {:error, {:invalid_operation, :invalid_expected_hash}} =
               Operation.new(%{
                 kind: :create,
                 file_path: "lib/file.ex",
                 content: "data",
                 expected_hash: "bad"
               })
    end

    test "allows create with empty string content" do
      assert {:ok, op} =
               Operation.new(%{
                 kind: :create,
                 file_path: "lib/empty.ex",
                 content: ""
               })

      assert op.content == ""
    end

    test "allows modify with empty string content" do
      assert {:ok, op} =
               Operation.new(%{
                 kind: :modify,
                 file_path: "lib/empty.ex",
                 content: ""
               })

      assert op.content == ""
    end

    test "allows modify with empty new_str in replacements" do
      assert {:ok, _op} =
               Operation.new(%{
                 kind: :modify,
                 file_path: "lib/file.ex",
                 replacements: [%{old_str: "foo", new_str: ""}]
               })
    end

    test "rejects replacement with non-binary new_str" do
      assert {:error, {:invalid_operation, :invalid_replacements}} =
               Operation.new(%{
                 kind: :modify,
                 file_path: "lib/file.ex",
                 replacements: [%{old_str: "foo", new_str: 123}]
               })
    end

    test "rejects replacement with empty old_str" do
      assert {:error, {:invalid_operation, :invalid_replacements}} =
               Operation.new(%{
                 kind: :modify,
                 file_path: "lib/file.ex",
                 replacements: [%{old_str: "", new_str: "bar"}]
               })
    end

    test "rejects replacement with non-binary old_str" do
      assert {:error, {:invalid_operation, :invalid_replacements}} =
               Operation.new(%{
                 kind: :modify,
                 file_path: "lib/file.ex",
                 replacements: [%{old_str: 123, new_str: "bar"}]
               })
    end
  end

  describe "new!/1" do
    test "creates or raises" do
      op = Operation.new!(%{kind: :create, file_path: "lib/f.ex", content: "data"})
      assert op.kind == :create

      assert_raise ArgumentError, fn ->
        Operation.new!(%{kind: :bad, file_path: "lib/f.ex"})
      end
    end
  end

  describe "to_map/1" do
    test "converts to JSON-friendly map" do
      op =
        Operation.new!(%{
          kind: :create,
          file_path: "lib/test.ex",
          content: "defmodule T do\nend\n"
        })

      map = Operation.to_map(op)
      assert map["kind"] == "create"
      assert map["file_path"] == "lib/test.ex"
      assert map["content"] == "defmodule T do\nend\n"
      refute Map.has_key?(map, "expected_hash")
    end

    test "only includes non-nil keys" do
      op = Operation.new!(%{kind: :delete, file_path: "lib/test.ex"})
      map = Operation.to_map(op)
      assert map["kind"] == "delete"
      assert map["file_path"] == "lib/test.ex"
      refute Map.has_key?(map, "content")
      refute Map.has_key?(map, "expected_hash")
    end
  end

  describe "kinds/0" do
    test "returns valid kinds" do
      assert Operation.kinds() == [:create, :modify, :delete]
    end
  end
end
