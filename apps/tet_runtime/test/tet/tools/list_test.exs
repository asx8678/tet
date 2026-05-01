defmodule Tet.Runtime.Tools.ListTest do
  use ExUnit.Case, async: true

  alias Tet.Runtime.Tools.List

  @workspace "/tmp/tet_test_list_#{System.unique_integer([:positive])}"

  setup do
    File.mkdir_p!(@workspace)
    File.write!(Path.join(@workspace, "a.txt"), "aaa")
    File.write!(Path.join(@workspace, "b.txt"), "bbb")
    File.mkdir_p!(Path.join(@workspace, "sub1"))
    File.write!(Path.join(@workspace, "sub1/c.txt"), "ccc")
    File.mkdir_p!(Path.join(@workspace, "sub1/deep"))
    File.write!(Path.join(@workspace, "sub1/deep/d.txt"), "ddd")
    File.mkdir_p!(Path.join(@workspace, "sub2"))

    on_exit(fn -> File.rm_rf!(@workspace) end)
    %{workspace: @workspace}
  end

  describe "run/2 — basic listing" do
    test "lists root directory entries", %{workspace: ws} do
      result = List.run(%{"path" => "."}, workspace_root: ws)

      assert result.ok == true
      assert result.data.directory == "."
      assert result.truncated == false
      # BD-0020 envelope
      assert result.error == nil
      assert result.correlation == nil
      assert result.redactions == []

      paths = Enum.map(result.data.entries, & &1.path)
      assert "a.txt" in paths
      assert "b.txt" in paths
      assert "sub1" in paths
      assert "sub2" in paths
    end

    test "lists subdirectory entries", %{workspace: ws} do
      result = List.run(%{"path" => "sub1"}, workspace_root: ws)

      assert result.ok == true
      paths = Enum.map(result.data.entries, & &1.path)
      assert "sub1/c.txt" in paths
      assert "sub1/deep" in paths
    end

    test "entries have correct types", %{workspace: ws} do
      result = List.run(%{"path" => "."}, workspace_root: ws)

      files = Enum.filter(result.data.entries, &(&1.type == "file"))
      dirs = Enum.filter(result.data.entries, &(&1.type == "directory"))

      file_paths = Enum.map(files, & &1.path)
      assert "a.txt" in file_paths
      assert "b.txt" in file_paths

      dir_paths = Enum.map(dirs, & &1.path)
      assert "sub1" in dir_paths
      assert "sub2" in dir_paths
    end

    test "entries have size_bytes for files", %{workspace: ws} do
      result = List.run(%{"path" => "."}, workspace_root: ws)

      a_entry = Enum.find(result.data.entries, &(&1.path == "a.txt"))
      assert a_entry.size_bytes == 3
    end

    test "summary counts are correct", %{workspace: ws} do
      result = List.run(%{"path" => "."}, workspace_root: ws)

      assert result.data.summary.entry_count == 4
      assert result.data.summary.file_count == 2
      assert result.data.summary.directory_count == 2
    end
  end

  describe "run/2 — recursive listing" do
    test "recursive lists all entries", %{workspace: ws} do
      result = List.run(%{"path" => ".", "recursive" => true}, workspace_root: ws)

      assert result.ok == true
      paths = Enum.map(result.data.entries, & &1.path)
      assert "a.txt" in paths
      assert "sub1/c.txt" in paths
      assert "sub1/deep/d.txt" in paths
    end

    test "recursive respects max_depth", %{workspace: ws} do
      result =
        List.run(%{"path" => ".", "recursive" => true, "max_depth" => 1}, workspace_root: ws)

      assert result.ok == true
      paths = Enum.map(result.data.entries, & &1.path)
      assert "sub1/c.txt" in paths
      refute "sub1/deep/d.txt" in paths
    end
  end

  describe "run/2 — error cases" do
    test "rejects workspace escape", %{workspace: ws} do
      result = List.run(%{"path" => "../etc"}, workspace_root: ws)

      assert result.ok == false
      assert result.data == nil
      assert result.error.code == "workspace_escape"
    end

    test "rejects non-existent directory", %{workspace: ws} do
      result = List.run(%{"path" => "nope"}, workspace_root: ws)

      assert result.ok == false
      assert result.error.code == "not_directory"
    end

    test "rejects file path instead of directory", %{workspace: ws} do
      result = List.run(%{"path" => "a.txt"}, workspace_root: ws)

      assert result.ok == false
      assert result.error.code == "not_directory"
    end

    test "returns standard envelope for all errors", %{workspace: ws} do
      result = List.run(%{"path" => "../etc"}, workspace_root: ws)

      assert result.ok == false
      assert result.data == nil
      assert result.error != nil
      assert result.correlation == nil
      assert result.redactions == []
      assert result.truncated == false
      assert result.limit_usage.paths.used == 0
      assert result.limit_usage.results.used == 0
    end
  end

  describe "run/2 — arg validation" do
    test "rejects invalid recursive arg", %{workspace: ws} do
      result = List.run(%{"path" => ".", "recursive" => "yes"}, workspace_root: ws)

      assert result.ok == false
      assert result.error.code == "invalid_arguments"
    end

    test "rejects invalid max_depth", %{workspace: ws} do
      result = List.run(%{"path" => ".", "max_depth" => -1}, workspace_root: ws)

      assert result.ok == false
      assert result.error.code == "invalid_arguments"
    end

    test "rejects max_depth over limit", %{workspace: ws} do
      result = List.run(%{"path" => ".", "max_depth" => 99}, workspace_root: ws)

      assert result.ok == false
      assert result.error.code == "invalid_arguments"
    end

    test "rejects non-string path", %{workspace: ws} do
      result = List.run(%{"path" => 42}, workspace_root: ws)

      assert result.ok == false
      assert result.error.code == "invalid_arguments"
    end
  end

  describe "run/2 — symlink listing" do
    test "rejects listing via escaping symlink directory", %{workspace: ws} do
      outside = "/tmp/tet_test_list_outside_#{System.unique_integer([:positive])}"
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret.txt"), "shh")
      on_exit(fn -> File.rm_rf!(outside) end)

      linkdir = Path.join(ws, "evil_link")
      File.ln_s!(outside, linkdir)

      result = List.run(%{"path" => "evil_link"}, workspace_root: ws)
      assert result.ok == false
      assert result.error.code == "workspace_escape"
    end

    test "lists symlinks that stay inside workspace", %{workspace: ws} do
      inside_link = Path.join(ws, "link_to_a")
      File.ln_s!("a.txt", inside_link)

      result = List.run(%{"path" => "."}, workspace_root: ws)

      assert result.ok == true
      link_entry = Enum.find(result.data.entries, &(&1.path == "link_to_a"))
      assert link_entry != nil
      assert link_entry.type == "symlink"
    end
  end

  describe "run/2 — envelope schema (BD-0020)" do
    test "success response has correct envelope keys", %{workspace: ws} do
      result = List.run(%{"path" => "."}, workspace_root: ws)

      assert Map.has_key?(result, :ok)
      assert Map.has_key?(result, :correlation)
      assert Map.has_key?(result, :data)
      assert Map.has_key?(result, :error)
      assert Map.has_key?(result, :redactions)
      assert Map.has_key?(result, :truncated)
      assert Map.has_key?(result, :limit_usage)
      assert result.error == nil
      assert result.redactions == []
    end

    test "error response has correct envelope keys", %{workspace: ws} do
      result = List.run(%{"path" => "../etc"}, workspace_root: ws)

      assert Map.has_key?(result, :ok)
      assert Map.has_key?(result, :correlation)
      assert Map.has_key?(result, :data)
      assert Map.has_key?(result, :error)
      assert Map.has_key?(result, :redactions)
      assert Map.has_key?(result, :truncated)
      assert Map.has_key?(result, :limit_usage)
      assert result.data == nil
      assert result.redactions == []
    end
  end

  describe "run/2 — truncation boundary (5000+ entries)" do
    test "non-recursive listing with 5001 entries reports truncated=true", %{workspace: ws} do
      # Setup creates 4 entries, so 4998 more + 4 = 5002 > 5000
      for i <- 1..4_998 do
        File.write!(Path.join(ws, "file_#{i}.txt"), "")
      end

      result = List.run(%{"path" => "."}, workspace_root: ws)

      assert result.ok == true

      assert result.truncated == true,
             "top-level truncated must be true when entries exceed 5000"

      assert result.data.summary.truncated == true,
             "data.summary.truncated must be true when entries exceed 5000"

      assert length(result.data.entries) == 5_000,
             "must return at most 5000 entries, got: #{length(result.data.entries)}"

      assert result.data.summary.entry_count <= 5_000
    end

    test "listing with exactly 5000 entries (including setup) does not report truncated", %{
      workspace: ws
    } do
      # Setup creates 4 entries, so we need 4996 more to hit 5000
      for i <- 1..4_996 do
        File.write!(Path.join(ws, "file_#{i}.txt"), "")
      end

      result = List.run(%{"path" => "."}, workspace_root: ws)

      assert result.ok == true

      assert result.truncated == false,
             "top-level truncated must be false at exactly 5000 entries"

      assert result.data.summary.truncated == false

      assert length(result.data.entries) == 5_000
    end

    test "listing with 4996 new entries (4999 + 4 setup = 5000 total) does not report truncated",
         %{workspace: ws} do
      # Setup has 4 entries (a.txt, b.txt, sub1, sub2)
      # Adding 4996 makes 5000 total
      for i <- 1..4_996 do
        File.write!(Path.join(ws, "file_#{i}.txt"), "")
      end

      result = List.run(%{"path" => "."}, workspace_root: ws)

      assert result.ok == true
      assert result.truncated == false
      assert result.data.summary.truncated == false
      assert length(result.data.entries) == 5_000
    end
  end

  describe "run/2 — rootlink/out ancestor escape" do
    test "rejects rootlink/out directory listing via ancestor symlinks", %{workspace: ws} do
      outside = "/tmp/tet_test_list_ancestor_#{System.unique_integer([:positive])}"
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret.txt"), "EVIL")
      on_exit(fn -> File.rm_rf!(outside) end)

      rootlink = Path.join(ws, "rootlink")
      File.ln_s!(".", rootlink)
      out_link = Path.join(ws, "out")
      File.ln_s!("../outside", out_link)

      result = List.run(%{"path" => "rootlink/out"}, workspace_root: ws)

      assert result.ok == false
      assert result.error.code == "workspace_escape"
      assert result.data == nil
    end
  end
end
