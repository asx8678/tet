defmodule Tet.Runtime.Tools.PatchTest do
  use ExUnit.Case, async: false

  alias Tet.Patch
  alias Tet.Runtime.Tools.Patch, as: PatchExecutor

  setup do
    # Create a temporary workspace
    tmp_dir = System.tmp_dir!() |> Path.join("tet_patch_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{workspace_root: tmp_dir}
  end

  defp touch(path, content \\ "original content\n") do
    parent = Path.dirname(path)
    File.mkdir_p!(parent)
    File.write!(path, content)
    path
  end

  describe "apply/2" do
    test "creates a new file", %{workspace_root: root} do
      patch =
        Patch.propose!(%{
          operations: [%{kind: :create, file_path: "lib/new.ex", content: "defmodule New do\nend\n"}],
          workspace_path: root
        })

      assert {:ok, result} =
               PatchExecutor.apply(patch,
                 approved: true,
                 tool_call_id: "call_1",
                 workspace_root: root
               )

      assert result.ok == true
      assert result.rolled_back == false
      assert File.exists?(Path.join(root, "lib/new.ex"))
      assert File.read!(Path.join(root, "lib/new.ex")) == "defmodule New do\nend\n"
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
                 approved: true,
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
                 approved: true,
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
                 approved: true,
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
                 approved: true,
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
                 approved: false,
                 tool_call_id: "call_no_approval",
                 workspace_root: root
               )

      assert result.ok == false
      assert result.error =~ "not approved"
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
                 approved: true,
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
                 approved: true,
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
                 approved: true,
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

      # Use a verifier that always fails
      verifier = {__MODULE__, :failing_verifier, []}

      assert {:ok, result} =
               PatchExecutor.apply(patch,
                 approved: true,
                 tool_call_id: "call_rollback",
                 workspace_root: root,
                 verifier: verifier
               )

      assert result.ok == true
      assert result.rolled_back == true
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
                 approved: true,
                 tool_call_id: "call_rollback_create",
                 workspace_root: root,
                 verifier: verifier
               )

      assert result.ok == true
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
                 approved: true,
                 tool_call_id: "call_rollback_delete",
                 workspace_root: root,
                 verifier: verifier
               )

      assert result.ok == true
      assert result.rolled_back == true

      # Deleted file should be restored
      assert File.read!(Path.join(root, "lib/to_restore.ex")) == "content to restore\n"
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
                 approved: true,
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
                 approved: true,
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

      assert {:ok, snapshots} = PatchExecutor.capture_pre_snapshots(patch, root)
      assert length(snapshots) == 2

      a_snap = Enum.find(snapshots, &(&1.file_path == "lib/a.ex"))
      assert a_snap.content == "content a\n"

      b_snap = Enum.find(snapshots, &(&1.file_path == "lib/b.ex"))
      assert b_snap.content == "content b\n"
    end

    test "skips snapshots for create operations", %{workspace_root: root} do
      patch =
        Patch.propose!(%{
          operations: [
            %{kind: :create, file_path: "lib/new.ex", content: "new\n"}
          ],
          workspace_path: root
        })

      assert {:ok, snapshots} = PatchExecutor.capture_pre_snapshots(patch, root)
      assert snapshots == []
    end
  end

  describe "perform_rollback/3" do
    test "restores modified files from snapshots", %{workspace_root: root} do
      file_path = "lib/restore.ex"
      abs_path = Path.join(root, file_path)
      touch(abs_path, "original\n")

      # Capture pre-apply snapshot
      pre_snapshot = Tet.Patch.Snapshot.pre_apply(file_path, "original\n")

      # Now modify the file
      File.write!(abs_path, "modified\n")

      patch =
        Patch.propose!(%{
          operations: [%{kind: :modify, file_path: file_path, content: "modified\n"}],
          workspace_path: root
        })

      rollback_output = PatchExecutor.perform_rollback(patch, [pre_snapshot], root)

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

      rollback_output = PatchExecutor.perform_rollback(patch, [], root)

      assert length(rollback_output.restored) == 1
      assert hd(rollback_output.restored).path == file_path

      # Created file should be removed
      refute File.exists?(abs_path)
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
      _first = PatchExecutor.perform_rollback(patch, [pre_snapshot], root)

      # Second rollback should be safe
      second = PatchExecutor.perform_rollback(patch, [pre_snapshot], root)

      assert length(second.restored) == 1
      # File should still be "original\n"
      assert File.read!(abs_path) == "original\n"
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
