defmodule Tet.Runtime.Tools.SearchTest do
  use ExUnit.Case, async: true

  alias Tet.Runtime.Tools.Search

  @workspace "/tmp/tet_test_search_#{System.unique_integer([:positive])}"

  setup do
    File.mkdir_p!(@workspace)
    File.write!(Path.join(@workspace, "hello.txt"), "hello world\nhello there\nbye now")
    File.write!(Path.join(@workspace, "stuff.txt"), "some stuff\nmore stuff\nfinal line")
    File.write!(Path.join(@workspace, "numbers.txt"), "123\n456\n789")

    File.mkdir_p!(Path.join(@workspace, "sub"))
    File.write!(Path.join(@workspace, "sub/nested.txt"), "nested hello\ndeep world")

    on_exit(fn -> File.rm_rf!(@workspace) end)

    %{workspace: @workspace}
  end

  defp skip_without_rg() do
    unless System.find_executable("rg") do
      :skip
    end
  end

  describe "run/2 — basic search" do
    test "finds literal matches", %{workspace: ws} do
      skip_without_rg()

      result = Search.run(%{"path" => ".", "query" => "hello"}, workspace_root: ws)

      assert result.ok == true
      assert result.data.summary.match_count >= 2
    end

    test "finds matches in subdirectories", %{workspace: ws} do
      skip_without_rg()

      result = Search.run(%{"path" => ".", "query" => "nested"}, workspace_root: ws)

      assert result.ok == true
      assert result.data.summary.match_count >= 1
    end

    test "returns empty matches for no results", %{workspace: ws} do
      skip_without_rg()

      result =
        Search.run(%{"path" => ".", "query" => "xyznonexistent_12345"}, workspace_root: ws)

      assert result.ok == true
      assert result.data.matches == []
      assert result.data.summary.match_count == 0
    end
  end

  describe "run/2 — search modes" do
    test "regex search works", %{workspace: ws} do
      skip_without_rg()

      result =
        Search.run(%{"path" => ".", "query" => "hello|world", "regex" => true},
          workspace_root: ws
        )

      assert result.ok == true
      assert result.data.summary.match_count >= 1
    end

    test "case-insensitive search works", %{workspace: ws} do
      skip_without_rg()

      result =
        Search.run(%{"path" => ".", "query" => "HELLO", "case_sensitive" => false},
          workspace_root: ws
        )

      assert result.ok == true
      assert result.data.summary.match_count >= 1
    end

    test "case-sensitive search by default filters case", %{workspace: ws} do
      skip_without_rg()

      result =
        Search.run(%{"path" => ".", "query" => "HELLO", "case_sensitive" => true},
          workspace_root: ws
        )

      assert result.ok == true
      assert result.data.summary.match_count == 0
    end
  end

  describe "run/2 — error cases" do
    test "rejects empty query" do
      result = Search.run(%{"path" => ".", "query" => ""}, workspace_root: "/tmp")

      assert result.ok == false
      assert result.error.code == "invalid_arguments"
    end

    test "rejects nil query" do
      result = Search.run(%{"path" => ".", "query" => nil}, workspace_root: "/tmp")

      assert result.ok == false
      assert result.error.code == "invalid_arguments"
    end

    test "rejects workspace escape in path", %{workspace: ws} do
      result = Search.run(%{"path" => "../etc", "query" => "hello"}, workspace_root: ws)

      assert result.ok == false
      assert result.error.code == "workspace_escape"
    end

    test "rejects null bytes in path", %{workspace: ws} do
      result =
        Search.run(%{"path" => "hello.txt\0evil", "query" => "hello"}, workspace_root: ws)

      assert result.ok == false
      assert result.error.code == "invalid_arguments"
    end
  end

  describe "run/2 — query injection prevention" do
    test "handles queries starting with dash", %{workspace: ws} do
      skip_without_rg()

      # Query starting with '-' should be treated as literal, not flag
      result = Search.run(%{"path" => ".", "query" => "-needle"}, workspace_root: ws)

      assert result.ok == true
      assert result.data.summary.match_count == 0
    end

    test "handles -f query", %{workspace: ws} do
      skip_without_rg()

      result = Search.run(%{"path" => ".", "query" => "-f"}, workspace_root: ws)

      assert result.ok == true
    end

    test "handles --files query", %{workspace: ws} do
      skip_without_rg()

      result = Search.run(%{"path" => ".", "query" => "--files"}, workspace_root: ws)

      assert result.ok == true
    end
  end

  describe "run/2 — include/exclude globs" do
    test "include_globs filters matches to matching files", %{workspace: ws} do
      skip_without_rg()

      result =
        Search.run(%{"path" => ".", "query" => "stuff", "include_globs" => ["*.txt"]},
          workspace_root: ws
        )

      assert result.ok == true
      assert result.data.summary.match_count >= 1
    end
  end

  describe "run/2 — arg validation" do
    test "rejects non-string path" do
      result = Search.run(%{"path" => 42, "query" => "hello"}, workspace_root: "/tmp")

      assert result.ok == false
      assert result.error.code == "invalid_arguments"
    end

    test "rejects non-boolean regex", %{workspace: ws} do
      result =
        Search.run(%{"path" => ".", "query" => "hello", "regex" => "yes"},
          workspace_root: ws
        )

      assert result.ok == false
      assert result.error.code == "invalid_arguments"
    end

    test "rejects non-boolean case_sensitive", %{workspace: ws} do
      result =
        Search.run(%{"path" => ".", "query" => "hello", "case_sensitive" => "maybe"},
          workspace_root: ws
        )

      assert result.ok == false
      assert result.error.code == "invalid_arguments"
    end

    test "rejects non-list include_globs", %{workspace: ws} do
      result =
        Search.run(%{"path" => ".", "query" => "hello", "include_globs" => "*.txt"},
          workspace_root: ws
        )

      assert result.ok == false
      assert result.error.code == "invalid_arguments"
    end

    test "rejects non-list exclude_globs", %{workspace: ws} do
      result =
        Search.run(%{"path" => ".", "query" => "hello", "exclude_globs" => 42},
          workspace_root: ws
        )

      assert result.ok == false
      assert result.error.code == "invalid_arguments"
    end
  end
end
