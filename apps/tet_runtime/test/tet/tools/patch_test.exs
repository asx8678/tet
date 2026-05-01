defmodule Tet.Runtime.Tools.PatchTest do
  use ExUnit.Case, async: false

  alias Tet.Patch
  alias Tet.Runtime.Tools.Patch, as: PatchExecutor

  setup do
    # Create a temporary workspace
    tmp_dir =
      System.tmp_dir!() |> Path.join("tet_patch_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{workspace_root: tmp_dir}
  end

  defp touch(path, content) do
    parent = Path.dirname(path)
    File.mkdir_p!(parent)
    File.write!(path, content)
    path
  end

  describe "apply/2" do
    test "creates a new file", %{workspace_root: root} do
      patch =
        Patch.propose!(%{
          operations: [
            %{kind: :create, file_path: "lib/new.ex", content: "defmodule New do\nend\n"}
          ],
          workspace_path: root
        })

      assert {:ok, result} =
               PatchExecutor.apply(patch,
                 approved: :approved,
                 tool_call_id: "call_1",
                 workspace_root: root
               )

      assert result.ok == true
      assert result.rolled_back == false
      assert File.exists?(Path.join(root, "lib/new.ex"))
      assert File.read!(Path.join(root, "lib/new.ex")) == "defmodule New do\nend\n"
    end

    test "rejects :create if target file already exists", %{workspace_root: root} do
      touch(Path.join(root, "lib/existing.ex"), "i exist\n")

      patch =
        Patch.propose!(%{
          operations: [%{kind: :create, file_path: "lib/existing.ex", content: "overwrite me\n"}],
          workspace_path: root
        })

      assert {:ok, result} =
               PatchExecutor.apply(patch,
                 approved: :approved,
                 tool_call_id: "call_overwrite",
                 workspace_root: root
               )

      assert result.ok == false
      assert result.error =~ "file already exists"
      # Content should remain unchanged
      assert File.read!(Path.join(root, "lib/existing.ex")) == "i exist\n"
    end

    test "modifies an existing file with full content", %{workspace_root: root} do
      path = touch(Path.join(root, "lib/existing.ex"), "old content\n")
      _ = path

      patch =
        Patch.propose!(%{
          operations: [%{kind: :modify, file_path: "lib/existing.ex", content: "new content\n"}],
          workspace_path: root
        })

      assert {:ok, result} =
               PatchExecutor.apply(patch,
                 approved: :approved,
                 tool_call_id: "call_2",
                 workspace_root: root
               )

      assert result.ok == true
      assert File.read!(Path.join(root, "lib/existing.ex")) == "new content\n"
    end

    test "modifies with old_str/new_str replacement", %{workspace_root: root} do
      path = touch(Path.join(root, "lib/replace.ex"), "Hello World\n")
      _ = path

      patch =
        Patch.propose!(%{
          operations: [
            %{
              kind: :modify,
              file_path: "lib/replace.ex",
              old_str: "World",
              new_str: "Elixir"
            }
          ],
          workspace_path: root
        })

      assert {:ok, _result} =
               PatchExecutor.apply(patch,
                 approved: :approved,
                 tool_call_id: "call_3",
                 workspace_root: root
               )

      assert File.read!(Path.join(root, "lib/replace.ex")) == "Hello Elixir\n"
    end

    test "modifies with replacements list", %{workspace_root: root} do
      path = touch(Path.join(root, "lib/multi.ex"), "aaa bbb ccc\n")
      _ = path

      patch =
        Patch.propose!(%{
          operations: [
            %{
              kind: :modify,
              file_path: "lib/multi.ex",
              replacements: [%{old_str: "aaa", new_str: "AAA"}, %{old_str: "bbb", new_str: "BBB"}]
            }
          ],
          workspace_path: root
        })

      assert {:ok, _result} =
               PatchExecutor.apply(patch,
                 approved: :approved,
                 tool_call_id: "call_4",
                 workspace_root: root
               )

      content = File.read!(Path.join(root, "lib/multi.ex"))
      assert content == "AAA BBB ccc\n"
    end

    test "deletes an existing file", %{workspace_root: root} do
      path = touch(Path.join(root, "lib/to_delete.ex"), "delete me\n")
      _ = path

      patch =
        Patch.propose!(%{
          operations: [%{kind: :delete, file_path: "lib/to_delete.ex"}],
          workspace_path: root
        })

      assert {:ok, _result} =
               PatchExecutor.apply(patch,
                 approved: :approved,
                 tool_call_id: "call_5",
                 workspace_root: root
               )

      refute File.exists?(Path.join(root, "lib/to_delete.ex"))
    end

    test "blocks apply without approval", %{workspace_root: root} do
      patch =
        Patch.propose!(%{
          operations: [%{kind: :create, file_path: "lib/new.ex", content: "x"}],
          workspace_path: root
        })

      assert {:ok, result} =
               PatchExecutor.apply(patch,
                 approved: :rejected,
                 tool_call_id: "call_no_approval",
                 workspace_root: root
               )

      assert result.ok == false
      assert result.error =~ "not approved"
    end

    test "rejects unknown approval status", %{workspace_root: root} do
      patch =
        Patch.propose!(%{
          operations: [%{kind: :create, file_path: "lib/new.ex", content: "x"}],
          workspace_path: root
        })

      # The old boolean `true` is not a valid approval status atom
      assert {:ok, result} =
               PatchExecutor.apply(patch,
                 approved: true,
                 tool_call_id: "call_spoof",
                 workspace_root: root
               )

      assert result.ok == false
      assert result.error =~ "invalid approval status"
    end

    test "captures pre-apply snapshots", %{workspace_root: root} do
      touch(Path.join(root, "lib/snap.ex"), "before\n")

      patch =
        Patch.propose!(%{
          operations: [
            %{kind: :modify, file_path: "lib/snap.ex", content: "after\n"}
          ],
          workspace_path: root
        })

      assert {:ok, result} =
               PatchExecutor.apply(patch,
                 approved: :approved,
                 tool_call_id: "call_snap",
                 workspace_root: root
               )

      assert length(result.pre_snapshots) == 1
      pre_snap = hd(result.pre_snapshots)
      assert pre_snap.captured_at == :pre_apply
      assert pre_snap.content == "before\n"
    end

    test "captures post-apply snapshots after success", %{workspace_root: root} do
      touch(Path.join(root, "lib/post.ex"), "before\n")

      patch =
        Patch.propose!(%{
          operations: [
            %{kind: :modify, file_path: "lib/post.ex", content: "after\n"}
          ],
          workspace_path: root
        })

      assert {:ok, result} =
               PatchExecutor.apply(patch,
                 approved: :approved,
                 tool_call_id: "call_post",
                 workspace_root: root
               )

      assert length(result.post_snapshots) == 1
      post_snap = hd(result.post_snapshots)
      assert post_snap.captured_at == :post_apply
      assert post_snap.content == "after\n"
    end

    test "applies multiple operations in order", %{workspace_root: root} do
      touch(Path.join(root, "lib/existing.ex"), "original\n")

      patch =
        Patch.propose!(%{
          operations: [
            %{kind: :create, file_path: "lib/created.ex", content: "new file\n"},
            %{kind: :modify, file_path: "lib/existing.ex", content: "modified\n"},
            %{kind: :delete, file_path: "lib/to_delete.ex", content: nil}
          ],
          workspace_path: root
        })

      # Touch the file to delete
      touch(Path.join(root, "lib/to_delete.ex"), "will be deleted\n")

      assert {:ok, result} =
               PatchExecutor.apply(patch,
                 approved: :approved,
                 tool_call_id: "call_multi",
                 workspace_root: root
               )

      assert result.ok == true
      assert length(result.applied) == 3
      assert File.exists?(Path.join(root, "lib/created.ex"))
      assert File.read!(Path.join(root, "lib/existing.ex")) == "modified\n"
      refute File.exists?(Path.join(root, "lib/to_delete.ex"))
    end
  end

  describe "rollback behavior" do
    test "rolls back modified files on verifier failure", %{workspace_root: root} do
      touch(Path.join(root, "lib/rollback.ex"), "original content\n")

      patch =
        Patch.propose!(%{
          operations: [
            %{kind: :modify, file_path: "lib/rollback.ex", content: "modified content\n"}
          ],
          workspace_path: root
        })

      verifier = {__MODULE__, :failing_verifier, []}

      assert {:ok, result} =
               PatchExecutor.apply(patch,
                 approved: :approved,
                 tool_call_id: "call_rollback",
                 workspace_root: root,
                 verifier: verifier
               )

      # Issue 2 — Verifier failure must return ok: false
      assert result.ok == false
      assert result.rolled_back == true
      assert result.error == "Verifier failed"
      assert result.rollback_output != nil

      # File should be restored to original
      assert File.read!(Path.join(root, "lib/rollback.ex")) == "original content\n"
    end

    test "rolls back created files on verifier failure", %{workspace_root: root} do
      patch =
        Patch.propose!(%{
          operations: [
            %{kind: :create, file_path: "lib/new_rollback.ex", content: "new file content\n"}
          ],
          workspace_path: root
        })

      verifier = {__MODULE__, :failing_verifier, []}

      assert {:ok, result} =
               PatchExecutor.apply(patch,
                 approved: :approved,
                 tool_call_id: "call_rollback_create",
                 workspace_root: root,
                 verifier: verifier
               )

      # Issue 2 — Verifier failure must return ok: false
      assert result.ok == false
      assert result.rolled_back == true

      # Created file should be removed
      refute File.exists?(Path.join(root, "lib/new_rollback.ex"))
    end

    test "rolls back deleted files on verifier failure", %{workspace_root: root} do
      touch(Path.join(root, "lib/to_restore.ex"), "content to restore\n")

      patch =
        Patch.propose!(%{
          operations: [
            %{kind: :delete, file_path: "lib/to_restore.ex"}
          ],
          workspace_path: root
        })

      verifier = {__MODULE__, :failing_verifier, []}

      assert {:ok, result} =
               PatchExecutor.apply(patch,
                 approved: :approved,
                 tool_call_id: "call_rollback_delete",
                 workspace_root: root,
                 verifier: verifier
               )

      # Issue 2 — Verifier failure must return ok: false
      assert result.ok == false
      assert result.rolled_back == true

      # Deleted file should be restored
      assert File.read!(Path.join(root, "lib/to_restore.ex")) == "content to restore\n"
    end

    test "does not delete pre-existing file on create+rollback", %{workspace_root: root} do
      # Issue 3 — :create on existing file is rejected; but if somehow created
      # (e.g. via multi-op where a create target file was already there),
      # rollback must not delete it. Here we test the verifier-failure path
      # where a create happened on a pre-existing file.
      touch(Path.join(root, "lib/preexisting.ex"), "i was here first\n")

      patch =
        Patch.propose!(%{
          operations: [
            %{kind: :create, file_path: "lib/preexisting.ex", content: "new content\n"}
          ],
          workspace_path: root
        })

      # The create is rejected because the file already exists
      assert {:ok, result} =
               PatchExecutor.apply(patch,
                 approved: :approved,
                 tool_call_id: "call_preexisting",
                 workspace_root: root
               )

      assert result.ok == false
      assert result.error =~ "file already exists"

      # Pre-existing file must remain intact
      assert File.read!(Path.join(root, "lib/preexisting.ex")) == "i was here first\n"
    end

    test "partial apply rolls back previous operations on failure", %{workspace_root: root} do
      # Issue 1 — If operation 2 fails, operation 1 must be rolled back
      touch(Path.join(root, "lib/to_modify.ex"), "original content\n")
      touch(Path.join(root, "lib/to_fail.ex"), "some content\n")

      # Op 1: modify succeeds. Op 2: modify with old_str that doesn't match.
      # This passes validation but fails at execution time.
      patch =
        Patch.propose!(%{
          operations: [
            %{kind: :modify, file_path: "lib/to_modify.ex", content: "modified\n"},
            %{kind: :modify, file_path: "lib/to_fail.ex", old_str: "NONEXISTENT", new_str: "x"}
          ],
          workspace_path: root
        })

      assert {:ok, result} =
               PatchExecutor.apply(patch,
                 approved: :approved,
                 tool_call_id: "call_partial",
                 workspace_root: root
               )

      # Operation 2 should fail (old_str not found) and trigger rollback
      assert result.ok == false
      assert result.rolled_back == true
      assert result.rollback_output != nil

      # File from operation 1 must be restored to original
      assert File.read!(Path.join(root, "lib/to_modify.ex")) == "original content\n"
    end

    test "passes verifier without rollback", %{workspace_root: root} do
      touch(Path.join(root, "lib/verify_ok.ex"), "original\n")

      patch =
        Patch.propose!(%{
          operations: [
            %{kind: :modify, file_path: "lib/verify_ok.ex", content: "modified\n"}
          ],
          workspace_path: root
        })

      verifier = {__MODULE__, :passing_verifier, []}

      assert {:ok, result} =
               PatchExecutor.apply(patch,
                 approved: :approved,
                 tool_call_id: "call_verify_ok",
                 workspace_root: root,
                 verifier: verifier
               )

      assert result.ok == true
      assert result.rolled_back == false
      assert result.verifier_output == %{exit_code: 0}

      # File should retain the modification
      assert File.read!(Path.join(root, "lib/verify_ok.ex")) == "modified\n"
    end

    test "skips verifier when skip_verifier is set", %{workspace_root: root} do
      patch =
        Patch.propose!(%{
          operations: [
            %{kind: :create, file_path: "lib/skip_v.ex", content: "content\n"}
          ],
          workspace_path: root
        })

      verifier = {__MODULE__, :failing_verifier, []}

      assert {:ok, result} =
               PatchExecutor.apply(patch,
                 approved: :approved,
                 tool_call_id: "call_skip_v",
                 workspace_root: root,
                 verifier: verifier,
                 skip_verifier: true
               )

      assert result.ok == true
      assert result.rolled_back == false
    end
  end

  describe "capture_pre_snapshots/2" do
    test "captures snapshots for modify operations", %{workspace_root: root} do
      touch(Path.join(root, "lib/a.ex"), "content a\n")
      touch(Path.join(root, "lib/b.ex"), "content b\n")

      patch =
        Patch.propose!(%{
          operations: [
            %{kind: :modify, file_path: "lib/a.ex", content: "new a\n"},
            %{kind: :modify, file_path: "lib/b.ex", content: "new b\n"}
          ],
          workspace_path: root
        })

      assert {:ok, snapshots, pre_existing} = PatchExecutor.capture_pre_snapshots(patch, root)
      assert length(snapshots) == 2

      a_snap = Enum.find(snapshots, &(&1.file_path == "lib/a.ex"))
      assert a_snap.content == "content a\n"

      b_snap = Enum.find(snapshots, &(&1.file_path == "lib/b.ex"))
      assert b_snap.content == "content b\n"

      # No create ops, so pre_existing should be empty
      assert pre_existing == []
    end

    test "skips snapshots for create operations", %{workspace_root: root} do
      patch =
        Patch.propose!(%{
          operations: [
            %{kind: :create, file_path: "lib/new.ex", content: "new\n"}
          ],
          workspace_path: root
        })

      assert {:ok, snapshots, pre_existing} = PatchExecutor.capture_pre_snapshots(patch, root)
      assert snapshots == []
      # create target does not exist, so pre_existing is empty
      assert pre_existing == []
    end

    test "tracks pre-existing files for create operations", %{workspace_root: root} do
      touch(Path.join(root, "lib/already_there.ex"), "i exist\n")

      patch =
        Patch.propose!(%{
          operations: [
            %{kind: :create, file_path: "lib/already_there.ex", content: "new\n"}
          ],
          workspace_path: root
        })

      assert {:ok, snapshots, pre_existing} = PatchExecutor.capture_pre_snapshots(patch, root)
      assert snapshots == []
      # pre_existing should include the create target that already has a file
      assert "lib/already_there.ex" in pre_existing
    end
  end

  describe "perform_rollback/4" do
    test "restores modified files from snapshots", %{workspace_root: root} do
      file_path = "lib/restore.ex"
      abs_path = Path.join(root, file_path)
      touch(abs_path, "original\n")

      pre_snapshot = Tet.Patch.Snapshot.pre_apply(file_path, "original\n")

      # Now modify the file
      File.write!(abs_path, "modified\n")

      patch =
        Patch.propose!(%{
          operations: [%{kind: :modify, file_path: file_path, content: "modified\n"}],
          workspace_path: root
        })

      rollback_output = PatchExecutor.perform_rollback(patch, [pre_snapshot], [], root)

      assert length(rollback_output.restored) == 1
      assert hd(rollback_output.restored).path == file_path
      assert hd(rollback_output.restored).action == :restored

      # File should be restored
      assert File.read!(abs_path) == "original\n"
    end

    test "removes created files on rollback", %{workspace_root: root} do
      file_path = "lib/created_rollback.ex"
      abs_path = Path.join(root, file_path)
      File.mkdir_p!(Path.dirname(abs_path))
      File.write!(abs_path, "new content\n")

      patch =
        Patch.propose!(%{
          operations: [%{kind: :create, file_path: file_path, content: "new content\n"}],
          workspace_path: root
        })

      rollback_output = PatchExecutor.perform_rollback(patch, [], [], root)

      assert length(rollback_output.restored) == 1
      assert hd(rollback_output.restored).path == file_path

      # Created file should be removed
      refute File.exists?(abs_path)
    end

    test "does not delete pre-existing file on rollback of create", %{workspace_root: root} do
      # Issue 3 — When a :create targets a file that already existed before
      # the patch, rollback must not delete it.
      file_path = "lib/existing_rollback.ex"
      abs_path = Path.join(root, file_path)
      touch(abs_path, "i was here before the patch\n")

      patch =
        Patch.propose!(%{
          operations: [%{kind: :create, file_path: file_path, content: "new\n"}],
          workspace_path: root
        })

      # Pre-existing list contains this file
      rollback_output = PatchExecutor.perform_rollback(patch, [], [file_path], root)

      # File should be skipped, not deleted
      assert length(rollback_output.skipped) == 1
      assert hd(rollback_output.skipped).path == file_path
      assert hd(rollback_output.skipped).reason == :pre_existing

      # File must still exist
      assert File.exists?(abs_path)
      assert File.read!(abs_path) == "i was here before the patch\n"
    end

    test "handles idempotent rollback (safe to run twice)", %{workspace_root: root} do
      file_path = "lib/idempotent.ex"
      abs_path = Path.join(root, file_path)
      touch(abs_path, "original\n")

      pre_snapshot = Tet.Patch.Snapshot.pre_apply(file_path, "original\n")
      File.write!(abs_path, "modified\n")

      patch =
        Patch.propose!(%{
          operations: [%{kind: :modify, file_path: file_path, content: "modified\n"}],
          workspace_path: root
        })

      # First rollback
      _first = PatchExecutor.perform_rollback(patch, [pre_snapshot], [], root)

      # Second rollback should be safe
      second = PatchExecutor.perform_rollback(patch, [pre_snapshot], [], root)

      assert length(second.restored) == 1
      # File should still be "original\n"
      assert File.read!(abs_path) == "original\n"
    end
  end

  describe "expected_hash enforcement" do
    test "modify rejects hash mismatch", %{workspace_root: root} do
      path = touch(Path.join(root, "lib/hash_check.ex"), "original content\n")
      _ = path

      wrong_hash = String.duplicate("a", 64)

      patch =
        Patch.propose!(%{
          operations: [
            %{
              kind: :modify,
              file_path: "lib/hash_check.ex",
              content: "new content\n",
              expected_hash: wrong_hash
            }
          ],
          workspace_path: root
        })

      assert {:ok, result} =
               PatchExecutor.apply(patch,
                 approved: :approved,
                 tool_call_id: "call_hash_mismatch",
                 workspace_root: root
               )

      assert result.ok == false
      assert result.errors != []
      assert elem(hd(result.errors), 0) == :hash_mismatch

      # File must NOT be mutated
      assert File.read!(Path.join(root, "lib/hash_check.ex")) == "original content\n"
    end

    test "modify with matching expected_hash succeeds", %{workspace_root: root} do
      path = touch(Path.join(root, "lib/hash_ok.ex"), "content\n")
      content = File.read!(path)
      actual_hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

      patch =
        Patch.propose!(%{
          operations: [
            %{
              kind: :modify,
              file_path: "lib/hash_ok.ex",
              content: "updated\n",
              expected_hash: actual_hash
            }
          ],
          workspace_path: root
        })

      assert {:ok, result} =
               PatchExecutor.apply(patch,
                 approved: :approved,
                 tool_call_id: "call_hash_ok",
                 workspace_root: root
               )

      assert result.ok == true
      assert File.read!(Path.join(root, "lib/hash_ok.ex")) == "updated\n"
    end

    test "modify with old_str rejects hash mismatch", %{workspace_root: root} do
      path = touch(Path.join(root, "lib/hash_oldstr.ex"), "Hello World\n")
      _ = path

      patch =
        Patch.propose!(%{
          operations: [
            %{
              kind: :modify,
              file_path: "lib/hash_oldstr.ex",
              old_str: "World",
              new_str: "Elixir",
              expected_hash: String.duplicate("b", 64)
            }
          ],
          workspace_path: root
        })

      assert {:ok, result} =
               PatchExecutor.apply(patch,
                 approved: :approved,
                 tool_call_id: "call_hash_oldstr",
                 workspace_root: root
               )

      assert result.ok == false
      assert File.read!(Path.join(root, "lib/hash_oldstr.ex")) == "Hello World\n"
    end

    test "modify with replacements rejects hash mismatch", %{workspace_root: root} do
      path = touch(Path.join(root, "lib/hash_repl.ex"), "aaa bbb\n")
      _ = path

      patch =
        Patch.propose!(%{
          operations: [
            %{
              kind: :modify,
              file_path: "lib/hash_repl.ex",
              replacements: [%{old_str: "aaa", new_str: "AAA"}],
              expected_hash: String.duplicate("c", 64)
            }
          ],
          workspace_path: root
        })

      assert {:ok, result} =
               PatchExecutor.apply(patch,
                 approved: :approved,
                 tool_call_id: "call_hash_repl",
                 workspace_root: root
               )

      assert result.ok == false
      assert File.read!(Path.join(root, "lib/hash_repl.ex")) == "aaa bbb\n"
    end

    test "delete rejects hash mismatch", %{workspace_root: root} do
      path = touch(Path.join(root, "lib/hash_delete.ex"), "delete me\n")
      _ = path

      patch =
        Patch.propose!(%{
          operations: [
            %{
              kind: :delete,
              file_path: "lib/hash_delete.ex",
              expected_hash: String.duplicate("d", 64)
            }
          ],
          workspace_path: root
        })

      assert {:ok, result} =
               PatchExecutor.apply(patch,
                 approved: :approved,
                 tool_call_id: "call_hash_del",
                 workspace_root: root
               )

      assert result.ok == false
      # File must NOT be deleted
      assert File.exists?(Path.join(root, "lib/hash_delete.ex"))
    end

    test "delete with matching expected_hash succeeds", %{workspace_root: root} do
      path = touch(Path.join(root, "lib/hash_del_ok.ex"), "delete me\n")
      content = File.read!(path)
      actual_hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

      patch =
        Patch.propose!(%{
          operations: [
            %{
              kind: :delete,
              file_path: "lib/hash_del_ok.ex",
              expected_hash: actual_hash
            }
          ],
          workspace_path: root
        })

      assert {:ok, _result} =
               PatchExecutor.apply(patch,
                 approved: :approved,
                 tool_call_id: "call_hash_del_ok",
                 workspace_root: root
               )

      refute File.exists?(Path.join(root, "lib/hash_del_ok.ex"))
    end

    test "hash mismatch in first op stops patch without rolling back", %{workspace_root: root} do
      path = touch(Path.join(root, "lib/hash_first.ex"), "first\n")
      _ = path
      touch(Path.join(root, "lib/hash_second.ex"), "second\n")

      patch =
        Patch.propose!(%{
          operations: [
            %{
              kind: :modify,
              file_path: "lib/hash_first.ex",
              content: "modified first\n",
              expected_hash: String.duplicate("e", 64)
            },
            %{
              kind: :modify,
              file_path: "lib/hash_second.ex",
              content: "modified second\n"
            }
          ],
          workspace_path: root
        })

      assert {:ok, result} =
               PatchExecutor.apply(patch,
                 approved: :approved,
                 tool_call_id: "call_hash_first",
                 workspace_root: root
               )

      assert result.ok == false
      # First op failed due to hash mismatch, so nothing was modified
      assert File.read!(Path.join(root, "lib/hash_first.ex")) == "first\n"
      assert File.read!(Path.join(root, "lib/hash_second.ex")) == "second\n"
    end
  end

  describe "run_verifier/4" do
    test "returns nil when no verifier given" do
      assert PatchExecutor.run_verifier(nil, [], "call_1", "task_1") == nil
    end

    test "calls the verifier MFA" do
      verifier = {__MODULE__, :passing_verifier, []}
      result = PatchExecutor.run_verifier(verifier, [], "call_1", "task_1")
      assert result == %{exit_code: 0}
    end

    test "handles verifier that returns {:error, _}" do
      verifier = {__MODULE__, :error_verifier, []}
      result = PatchExecutor.run_verifier(verifier, [], "call_1", "task_1")
      assert result.error != nil
    end

    test "handles verifier that raises" do
      verifier = {__MODULE__, :raising_verifier, []}
      result = PatchExecutor.run_verifier(verifier, [], "call_1", "task_1")
      assert result.error =~ "raised"
    end
  end

  describe "valid_approval_status?/1" do
    test "accepts valid status atoms" do
      assert PatchExecutor.valid_approval_status?(:approved)
      assert PatchExecutor.valid_approval_status?(:rejected)
      assert PatchExecutor.valid_approval_status?(:pending)
      assert PatchExecutor.valid_approval_status?(:unknown)
    end

    test "rejects invalid statuses" do
      refute PatchExecutor.valid_approval_status?(true)
      refute PatchExecutor.valid_approval_status?(true)
      refute PatchExecutor.valid_approval_status?(:yes)
      refute PatchExecutor.valid_approval_status?("approved")
    end
  end

  # -- Verifier helpers for tests --

  def passing_verifier(_tool_call_id, _task_id) do
    {:ok, %{exit_code: 0}}
  end

  def failing_verifier(_tool_call_id, _task_id) do
    {:ok, %{exit_code: 1, stdout: "Tests failed\n"}}
  end

  def error_verifier(_tool_call_id, _task_id) do
    {:error, "Verifier error"}
  end

  def raising_verifier(_tool_call_id, _task_id) do
    raise RuntimeError, "Verifier crashed!"
  end
end
