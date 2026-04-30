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
      assert result.data.summary.truncated == false
    end
  end

  describe "run/2 — error cases" do
    test "rejects workspace escape", %{workspace: ws} do
      result = List.run(%{"path" => "../etc"}, workspace_root: ws)

      assert result.ok == false
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
  end
end
