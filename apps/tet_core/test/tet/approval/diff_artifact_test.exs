defmodule Tet.Approval.DiffArtifactTest do
  @moduledoc """
  BD-0027: DiffArtifact struct tests.

  Covers construction, validation, hash consistency, snapshot-based
  construction, serialization round-trips, and correlation metadata.
  """

  use ExUnit.Case, async: true

  alias Tet.Approval.{DiffArtifact, Snapshot}

  describe "new/1" do
    test "builds a valid diff artifact from required attrs" do
      attrs = %{
        id: "diff_001",
        tool_call_id: "call_abc",
        file_path: "/workspace/lib/foo.ex",
        content_hash_before: "hash_before",
        content_hash_after: "hash_after"
      }

      assert {:ok, artifact} = DiffArtifact.new(attrs)
      assert artifact.id == "diff_001"
      assert artifact.tool_call_id == "call_abc"
      assert artifact.file_path == "/workspace/lib/foo.ex"
      assert artifact.content_hash_before == "hash_before"
      assert artifact.content_hash_after == "hash_after"
      assert artifact.old_content == nil
      assert artifact.new_content == nil
      assert artifact.patch_text == nil
      assert artifact.metadata == %{}
    end

    test "builds diff artifact with all optional attrs" do
      old_content = "old content"
      new_content = "new content"
      before_hash = Snapshot.compute_hash(old_content)
      after_hash = Snapshot.compute_hash(new_content)

      attrs = %{
        id: "diff_002",
        tool_call_id: "call_xyz",
        file_path: "/workspace/lib/bar.ex",
        content_hash_before: before_hash,
        content_hash_after: after_hash,
        old_content: old_content,
        new_content: new_content,
        patch_text: "--- a/bar.ex\n+++ b/bar.ex\n@@ -1 +1 @@\n-old content\n+new content",
        snapshot_before_id: "snap_before",
        snapshot_after_id: "snap_after",
        session_id: "ses_001",
        task_id: "task_001",
        metadata: %{mutation: :write}
      }

      assert {:ok, artifact} = DiffArtifact.new(attrs)
      assert artifact.old_content == "old content"
      assert artifact.patch_text != nil
      assert artifact.snapshot_before_id == "snap_before"
      assert artifact.snapshot_after_id == "snap_after"
      assert artifact.session_id == "ses_001"
    end

    test "rejects missing id" do
      assert {:error, {:invalid_diff_artifact_field, :id}} =
               DiffArtifact.new(%{
                 tool_call_id: "c",
                 file_path: "/f",
                 content_hash_before: "h1",
                 content_hash_after: "h2"
               })
    end

    test "rejects missing tool_call_id" do
      assert {:error, {:invalid_diff_artifact_field, :tool_call_id}} =
               DiffArtifact.new(%{
                 id: "d1",
                 file_path: "/f",
                 content_hash_before: "h1",
                 content_hash_after: "h2"
               })
    end

    test "rejects missing file_path" do
      assert {:error, {:invalid_diff_artifact_field, :file_path}} =
               DiffArtifact.new(%{
                 id: "d1",
                 tool_call_id: "c",
                 content_hash_before: "h1",
                 content_hash_after: "h2"
               })
    end

    test "validates hash consistency for old_content" do
      content = "hello"
      correct_hash = Snapshot.compute_hash(content)

      # Correct hash passes
      assert {:ok, _} =
               DiffArtifact.new(%{
                 id: "d1",
                 tool_call_id: "c",
                 file_path: "/f",
                 content_hash_before: correct_hash,
                 content_hash_after: "h2",
                 old_content: content
               })

      # Wrong hash fails
      assert {:error, {:hash_mismatch, :content_hash_before, _computed, "wrong_hash"}} =
               DiffArtifact.new(%{
                 id: "d1",
                 tool_call_id: "c",
                 file_path: "/f",
                 content_hash_before: "wrong_hash",
                 content_hash_after: "h2",
                 old_content: content
               })
    end

    test "validates hash consistency for new_content" do
      content = "world"
      correct_hash = Snapshot.compute_hash(content)

      assert {:ok, _} =
               DiffArtifact.new(%{
                 id: "d1",
                 tool_call_id: "c",
                 file_path: "/f",
                 content_hash_before: "h1",
                 content_hash_after: correct_hash,
                 new_content: content
               })

      assert {:error, {:hash_mismatch, :content_hash_after, _computed, "wrong"}} =
               DiffArtifact.new(%{
                 id: "d1",
                 tool_call_id: "c",
                 file_path: "/f",
                 content_hash_before: "h1",
                 content_hash_after: "wrong",
                 new_content: content
               })
    end

    test "skips hash validation when content is nil" do
      assert {:ok, _} =
               DiffArtifact.new(%{
                 id: "d1",
                 tool_call_id: "c",
                 file_path: "/f",
                 content_hash_before: "any_hash",
                 content_hash_after: "any_other_hash"
               })
    end
  end

  describe "new!/1" do
    test "builds or raises" do
      attrs = %{
        id: "d1",
        tool_call_id: "c",
        file_path: "/f",
        content_hash_before: "h1",
        content_hash_after: "h2"
      }

      assert %DiffArtifact{} = DiffArtifact.new!(attrs)
    end

    test "raises on invalid attrs" do
      assert_raise ArgumentError, fn -> DiffArtifact.new!(%{id: ""}) end
    end
  end

  describe "from_snapshots/3" do
    test "builds diff artifact from before/after snapshots" do
      before_content = "old"
      after_content = "new"

      before_snap =
        Snapshot.new!(%{
          id: "snap_b",
          file_path: "/lib/foo.ex",
          content_hash: Snapshot.compute_hash(before_content),
          action: :taken_before,
          content: before_content,
          tool_call_id: "call_snap",
          session_id: "ses_snap",
          task_id: "task_snap"
        })

      after_snap =
        Snapshot.new!(%{
          id: "snap_a",
          file_path: "/lib/foo.ex",
          content_hash: Snapshot.compute_hash(after_content),
          action: :taken_after,
          content: after_content,
          tool_call_id: "call_snap",
          session_id: "ses_snap",
          task_id: "task_snap"
        })

      extra = %{id: "diff_snap", patch_text: "@@ -1 +1 @@\n-old\n+new"}

      assert {:ok, artifact} = DiffArtifact.from_snapshots(before_snap, after_snap, extra)
      assert artifact.id == "diff_snap"
      assert artifact.file_path == "/lib/foo.ex"
      assert artifact.content_hash_before == Snapshot.compute_hash(before_content)
      assert artifact.content_hash_after == Snapshot.compute_hash(after_content)
      assert artifact.snapshot_before_id == "snap_b"
      assert artifact.snapshot_after_id == "snap_a"
      assert artifact.old_content == "old"
      assert artifact.new_content == "new"
      assert artifact.tool_call_id == "call_snap"
      assert artifact.session_id == "ses_snap"
    end

    test "rejects mismatched file paths" do
      before_snap = %Snapshot{
        id: "sb",
        file_path: "/lib/a.ex",
        content_hash: "h1",
        action: :taken_before
      }

      after_snap = %Snapshot{
        id: "sa",
        file_path: "/lib/b.ex",
        content_hash: "h2",
        action: :taken_after
      }

      assert {:error, {:snapshot_file_path_mismatch, "/lib/a.ex", "/lib/b.ex"}} =
               DiffArtifact.from_snapshots(before_snap, after_snap, %{})
    end

    test "prefers before snapshot correlation when both have it" do
      before_snap = %Snapshot{
        id: "sb",
        file_path: "/f",
        content_hash: "h1",
        action: :taken_before,
        tool_call_id: "call_before",
        session_id: "ses_before"
      }

      after_snap = %Snapshot{
        id: "sa",
        file_path: "/f",
        content_hash: "h2",
        action: :taken_after,
        tool_call_id: "call_after",
        session_id: "ses_after"
      }

      assert {:ok, artifact} = DiffArtifact.from_snapshots(before_snap, after_snap, %{id: "d1"})
      assert artifact.tool_call_id == "call_before"
      assert artifact.session_id == "ses_before"
    end
  end

  describe "to_map/1 and from_map/1 round-trip" do
    test "round-trips a diff artifact" do
      artifact =
        DiffArtifact.new!(%{
          id: "diff_rt",
          tool_call_id: "call_rt",
          file_path: "/lib/foo.ex",
          content_hash_before: "hb_rt",
          content_hash_after: "ha_rt",
          snapshot_before_id: "snap_b",
          snapshot_after_id: "snap_a",
          session_id: "ses_rt",
          task_id: "task_rt",
          metadata: %{lines_changed: 5}
        })

      map = DiffArtifact.to_map(artifact)
      assert map.id == "diff_rt"
      assert map.file_path == "/lib/foo.ex"
      assert map.content_hash_before == "hb_rt"
      assert map.snapshot_before_id == "snap_b"

      assert {:ok, restored} = DiffArtifact.from_map(map)
      assert restored.id == artifact.id
      assert restored.file_path == artifact.file_path
      assert restored.content_hash_before == artifact.content_hash_before
      assert restored.snapshot_before_id == artifact.snapshot_before_id
      assert restored.session_id == artifact.session_id
    end
  end
end
