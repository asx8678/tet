defmodule Tet.Runtime.Tools.PathResolverTest do
  use ExUnit.Case, async: true

  alias Tet.Runtime.Tools.PathResolver

  @workspace "/tmp/tet_test_workspace_#{System.unique_integer([:positive])}"

  setup do
    File.mkdir_p!(@workspace)
    File.mkdir_p!(Path.join(@workspace, "sub/deep"))
    File.write!(Path.join(@workspace, "hello.txt"), "hello world")
    File.write!(Path.join(@workspace, "sub/nested.txt"), "nested content")

    on_exit(fn -> File.rm_rf!(@workspace) end)
    %{workspace: @workspace}
  end

  describe "resolve/2" do
    test "resolves a relative path inside workspace", %{workspace: ws} do
      assert {:ok, resolved} = PathResolver.resolve("hello.txt", ws)
      assert resolved == Path.join(ws, "hello.txt")
      assert String.starts_with?(resolved, ws)
    end

    test "resolves nested relative path", %{workspace: ws} do
      assert {:ok, resolved} = PathResolver.resolve("sub/nested.txt", ws)
      assert resolved == Path.join(ws, "sub/nested.txt")
    end

    test "resolves dot as workspace root", %{workspace: ws} do
      assert {:ok, resolved} = PathResolver.resolve(".", ws)
      assert resolved == ws
    end

    test "rejects absolute paths" do
      assert {:error, denial} = PathResolver.resolve("/etc/passwd", "/tmp")
      assert denial.code == "workspace_escape"
      assert denial.kind == "policy_denial"
      assert denial.retryable == false
    end

    test "rejects paths with null bytes" do
      assert {:error, denial} = PathResolver.resolve("hello.txt\0evil", "/tmp")
      assert denial.code == "invalid_arguments"
    end

    test "rejects simple traversal" do
      assert {:error, denial} = PathResolver.resolve("../etc/passwd", "/workspace")
      assert denial.code == "workspace_escape"
    end

    test "rejects deep traversal" do
      assert {:error, denial} = PathResolver.resolve("sub/../../etc/passwd", "/workspace")
      assert denial.code == "workspace_escape"
    end

    test "rejects layered traversal" do
      assert {:error, _denial} = PathResolver.resolve("a/b/../../../../etc/passwd", "/workspace")
    end

    test "accepts paths with dots that are not traversal", %{workspace: ws} do
      assert {:ok, resolved} = PathResolver.resolve("some.file.txt", ws)
      assert String.ends_with?(resolved, "some.file.txt")
    end

    test "accepts empty path components (multiple slashes)", %{workspace: ws} do
      assert {:ok, resolved} = PathResolver.resolve("sub//nested.txt", ws)
      assert String.ends_with?(resolved, "nested.txt")
    end
  end

  describe "resolve_file/2" do
    test "resolves an existing file", %{workspace: ws} do
      assert {:ok, resolved} = PathResolver.resolve_file("hello.txt", ws)
      assert resolved == Path.join(ws, "hello.txt")
    end

    test "rejects a non-existent file", %{workspace: ws} do
      assert {:error, denial} = PathResolver.resolve_file("nope.txt", ws)
      assert denial.code == "not_found"
    end

    test "rejects a directory path when file expected", %{workspace: ws} do
      assert {:error, denial} = PathResolver.resolve_file("sub", ws)
      assert denial.code == "not_file"
    end
  end

  describe "resolve_directory/2" do
    test "resolves an existing directory", %{workspace: ws} do
      assert {:ok, resolved} = PathResolver.resolve_directory(".", ws)
      assert resolved == ws
    end

    test "rejects a file path when directory expected", %{workspace: ws} do
      assert {:error, denial} = PathResolver.resolve_directory("hello.txt", ws)
      assert denial.code == "not_directory"
    end

    test "rejects a non-existent directory", %{workspace: ws} do
      assert {:error, denial} = PathResolver.resolve_directory("nope_dir", ws)
      assert denial.code == "not_directory"
    end
  end

  describe "symlink detection" do
    test "rejects symlink that escapes workspace", %{workspace: ws} do
      outside = "/tmp/tet_test_outside_#{System.unique_integer([:positive])}"
      File.write!(outside, "outside content")
      on_exit(fn -> File.rm(outside) end)

      link_path = Path.join(ws, "escape_link")
      File.ln_s!(outside, link_path)

      assert {:error, denial} = PathResolver.resolve("escape_link", ws)
      assert denial.code == "workspace_escape"
    end

    test "rejects read via workspace/linkdir/file where linkdir points outside", %{workspace: ws} do
      outside = "/tmp/tet_test_outside_dir_#{System.unique_integer([:positive])}"
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret.txt"), "outside content")
      on_exit(fn -> File.rm_rf!(outside) end)

      linkdir = Path.join(ws, "linkdir")
      File.ln_s!(outside, linkdir)

      assert {:error, denial} = PathResolver.resolve("linkdir/secret.txt", ws)
      assert denial.code == "workspace_escape"
    end

    test "rejects list via linkdir/subdir where linkdir points outside", %{workspace: ws} do
      outside = "/tmp/tet_test_outside_sub_#{System.unique_integer([:positive])}"
      File.mkdir_p!(outside)
      File.mkdir_p!(Path.join(outside, "subdir"))
      on_exit(fn -> File.rm_rf!(outside) end)

      linkdir = Path.join(ws, "linkdir")
      File.ln_s!(outside, linkdir)

      assert {:error, denial} = PathResolver.resolve("linkdir/subdir", ws)
      assert denial.code == "workspace_escape"
    end

    test "allows symlink that stays inside workspace", %{workspace: ws} do
      inside_target = Path.join(ws, "hello.txt")
      link_path = Path.join(ws, "inside_link")
      File.ln_s!(inside_target, link_path)

      assert {:ok, resolved} = PathResolver.resolve("inside_link", ws)
      assert String.starts_with?(resolved, ws)
    end

    test "allows relative symlink inside workspace", %{workspace: ws} do
      link_path = Path.join(ws, "rel_link")
      File.ln_s!("hello.txt", link_path)

      assert {:ok, resolved} = PathResolver.resolve("rel_link", ws)
      assert String.starts_with?(resolved, ws)
    end

    test "rejects nested symlink chain where intermediate escapes", %{workspace: ws} do
      outside = "/tmp/tet_test_nested_outside_#{System.unique_integer([:positive])}"
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "target.txt"), "escaped")
      on_exit(fn -> File.rm_rf!(outside) end)

      escape_link = Path.join(ws, "sub/escape_link")
      File.ln_s!(outside, escape_link)

      nested_link = Path.join(ws, "sub/nested_link")
      File.ln_s!("escape_link", nested_link)

      assert {:error, denial} = PathResolver.resolve("sub/nested_link/target.txt", ws)
      assert denial.code == "workspace_escape"
    end
  end

  describe "validate helpers" do
    test "validate_boolean rejects non-booleans" do
      assert {:error, d} = PathResolver.validate_boolean("yes", "flag")
      assert d.code == "invalid_arguments"

      assert {:error, d} = PathResolver.validate_boolean(1, "flag")
      assert d.code == "invalid_arguments"

      assert :ok = PathResolver.validate_boolean(true, "flag")
      assert :ok = PathResolver.validate_boolean(false, "flag")
    end

    test "validate_integer rejects non-integers and out-of-range" do
      assert {:error, d} = PathResolver.validate_integer("one", "count", 0, 10)
      assert d.code == "invalid_arguments"

      assert {:error, d} = PathResolver.validate_integer(-1, "count", 0, 10)
      assert d.code == "invalid_arguments"

      assert {:error, d} = PathResolver.validate_integer(20, "count", 0, 10)
      assert d.code == "invalid_arguments"

      assert :ok = PathResolver.validate_integer(5, "count", 0, 10)
      assert :ok = PathResolver.validate_integer(0, "count", 0)
    end

    test "validate_string rejects non-strings" do
      assert {:error, d} = PathResolver.validate_string(42, "name")
      assert d.code == "invalid_arguments"

      assert {:error, d} = PathResolver.validate_string(nil, "name")
      assert d.code == "invalid_arguments"

      assert :ok = PathResolver.validate_string("valid", "name")
    end

    test "validate_glob_list rejects non-lists and non-string elements" do
      assert {:error, d} = PathResolver.validate_glob_list("*.txt", "globs")
      assert d.code == "invalid_arguments"

      assert {:error, d} = PathResolver.validate_glob_list([:atom, 42], "globs")
      assert d.code == "invalid_arguments"

      assert :ok = PathResolver.validate_glob_list([], "globs")
      assert :ok = PathResolver.validate_glob_list(["*.txt", "*.ex"], "globs")
    end
  end
end
