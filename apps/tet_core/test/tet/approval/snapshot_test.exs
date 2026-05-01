defmodule Tet.Approval.SnapshotTest do
  @moduledoc """
  BD-0027: Snapshot struct tests.

  Covers construction, validation, content hashing, action types,
  serialization round-trips, and correlation metadata.
  """

  use ExUnit.Case, async: true

  alias Tet.Approval.Snapshot

  describe "new/1" do
    test "builds a valid snapshot from required attrs" do
      attrs = %{
        id: "snap_001",
        file_path: "/workspace/lib/foo.ex",
        content_hash: "abc123",
        action: :taken_before
      }

      assert {:ok, snapshot} = Snapshot.new(attrs)
      assert snapshot.id == "snap_001"
      assert snapshot.file_path == "/workspace/lib/foo.ex"
      assert snapshot.content_hash == "abc123"
      assert snapshot.action == :taken_before
      assert snapshot.content == nil
      assert snapshot.metadata == %{}
    end

    test "builds snapshot with all optional attrs" do
      content = "defmodule Foo do end"

      attrs = %{
        id: "snap_002",
        file_path: "/workspace/lib/bar.ex",
        content_hash: Snapshot.compute_hash(content),
        action: :taken_after,
        content: content,
        timestamp: "2025-05-01T12:00:00Z",
        tool_call_id: "call_abc",
        session_id: "ses_001",
        task_id: "task_001",
        metadata: %{mutation: :write}
      }

      assert {:ok, snapshot} = Snapshot.new(attrs)
      assert snapshot.content == "defmodule Foo do end"
      assert snapshot.tool_call_id == "call_abc"
      assert snapshot.session_id == "ses_001"
    end

    test "accepts string action via parsing" do
      attrs = %{
        id: "snap_003",
        file_path: "/workspace/lib/baz.ex",
        content_hash: "ghi789",
        action: "taken_after"
      }

      assert {:ok, snapshot} = Snapshot.new(attrs)
      assert snapshot.action == :taken_after
    end

    test "rejects missing id" do
      assert {:error, {:invalid_snapshot_field, :id}} =
               Snapshot.new(%{file_path: "/f", content_hash: "h", action: :taken_before})
    end

    test "rejects missing file_path" do
      assert {:error, {:invalid_snapshot_field, :file_path}} =
               Snapshot.new(%{id: "s1", content_hash: "h", action: :taken_before})
    end

    test "rejects missing content_hash" do
      assert {:error, {:invalid_snapshot_field, :content_hash}} =
               Snapshot.new(%{id: "s1", file_path: "/f", action: :taken_before})
    end

    test "rejects invalid action" do
      assert {:error, {:invalid_snapshot_field, :action}} =
               Snapshot.new(%{id: "s1", file_path: "/f", content_hash: "h", action: :unknown})
    end

    test "accepts DateTime timestamp" do
      now = DateTime.utc_now()

      attrs = %{
        id: "snap_ts",
        file_path: "/f",
        content_hash: "h",
        action: :taken_before,
        timestamp: now
      }

      assert {:ok, snapshot} = Snapshot.new(attrs)
      assert snapshot.timestamp == now
    end
  end

  describe "new!/1" do
    test "builds or raises" do
      attrs = %{id: "s1", file_path: "/f", content_hash: "h", action: :taken_before}
      assert %Snapshot{} = Snapshot.new!(attrs)
    end

    test "raises on invalid attrs" do
      assert_raise ArgumentError, fn -> Snapshot.new!(%{id: ""}) end
    end
  end

  describe "compute_hash/1" do
    test "computes SHA-256 hex hash" do
      content = "hello world"
      hash = Snapshot.compute_hash(content)

      assert is_binary(hash)
      assert byte_size(hash) == 64
      # SHA-256 of "hello world" is well-known
      assert hash == "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
    end

    test "different content produces different hash" do
      h1 = Snapshot.compute_hash("content a")
      h2 = Snapshot.compute_hash("content b")
      refute h1 == h2
    end
  end

  describe "from_content/1" do
    test "builds snapshot with auto-computed hash" do
      content = "defmodule Foo do end"

      attrs = %{
        id: "snap_fc",
        file_path: "/lib/foo.ex",
        action: :taken_before,
        content: content,
        tool_call_id: "call_1"
      }

      assert {:ok, snapshot} = Snapshot.from_content(attrs)
      assert snapshot.content_hash == Snapshot.compute_hash(content)
      assert snapshot.content == content
    end

    test "rejects missing content" do
      attrs = %{id: "s1", file_path: "/f", action: :taken_before}
      assert {:error, {:invalid_snapshot_field, :content}} = Snapshot.from_content(attrs)
    end
  end

  describe "before?/1 and after?/1" do
    test "before? returns true for taken_before" do
      snapshot = %Snapshot{id: "s1", file_path: "/f", content_hash: "h", action: :taken_before}
      assert Snapshot.before?(snapshot)
      refute Snapshot.after?(snapshot)
    end

    test "after? returns true for taken_after" do
      snapshot = %Snapshot{id: "s1", file_path: "/f", content_hash: "h", action: :taken_after}
      assert Snapshot.after?(snapshot)
      refute Snapshot.before?(snapshot)
    end
  end

  describe "to_map/1 and from_map/1 round-trip" do
    test "round-trips a snapshot" do
      snapshot =
        Snapshot.new!(%{
          id: "snap_rt",
          file_path: "/lib/foo.ex",
          content_hash: "hash123",
          action: :taken_before,
          tool_call_id: "call_rt",
          session_id: "ses_rt",
          task_id: "task_rt",
          metadata: %{line_count: 10}
        })

      map = Snapshot.to_map(snapshot)
      assert map.id == "snap_rt"
      assert map.action == "taken_before"
      assert map.content_hash == "hash123"
      assert map.tool_call_id == "call_rt"

      assert {:ok, restored} = Snapshot.from_map(map)
      assert restored.id == snapshot.id
      assert restored.action == snapshot.action
      assert restored.content_hash == snapshot.content_hash
      assert restored.session_id == snapshot.session_id
    end
  end

  describe "actions/0" do
    test "returns both action types" do
      actions = Snapshot.actions()
      assert :taken_before in actions
      assert :taken_after in actions
    end
  end
end
