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

  describe "run/2 — basic search" do
    test "finds literal matches", %{workspace: ws} do
      result = Search.run(%{"path" => ".", "query" => "hello"}, workspace_root: ws)

      assert result.ok == true
      assert result.data.summary.match_count >= 2
    end

    test "finds matches in subdirectories", %{workspace: ws} do
      result = Search.run(%{"path" => ".", "query" => "nested"}, workspace_root: ws)

      assert result.ok == true
      assert result.data.summary.match_count >= 1
    end

    test "returns empty matches for no results", %{workspace: ws} do
      result =
        Search.run(%{"path" => ".", "query" => "xyznonexistent_12345"}, workspace_root: ws)

      assert result.ok == true
      assert result.data.matches == []
      assert result.data.summary.match_count == 0
    end
  end

  describe "run/2 — search modes" do
    test "regex search works", %{workspace: ws} do
      result =
        Search.run(%{"path" => ".", "query" => "hello|world", "regex" => true},
          workspace_root: ws
        )

      assert result.ok == true
      assert result.data.summary.match_count >= 1
    end

    test "case-insensitive search works", %{workspace: ws} do
      result =
        Search.run(%{"path" => ".", "query" => "HELLO", "case_sensitive" => false},
          workspace_root: ws
        )

      assert result.ok == true
      assert result.data.summary.match_count >= 1
    end

    test "case-sensitive search by default filters case", %{workspace: ws} do
      result =
        Search.run(%{"path" => ".", "query" => "HELLO", "case_sensitive" => true},
          workspace_root: ws
        )

      assert result.ok == true
      assert result.data.summary.match_count == 0
    end
  end

  describe "run/2 — error cases" do
    test "rejects empty query", %{workspace: ws} do
      result = Search.run(%{"path" => ".", "query" => ""}, workspace_root: ws)

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

  describe "run/2 — include/exclude globs" do
    test "include_globs filters matches to matching files", %{workspace: ws} do
      result =
        Search.run(%{"path" => ".", "query" => "stuff", "include_globs" => ["*.txt"]},
          workspace_root: ws
        )

      assert result.ok == true
      assert result.data.summary.match_count >= 1
    end
  end
end
