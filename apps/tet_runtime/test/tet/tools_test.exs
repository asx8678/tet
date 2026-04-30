defmodule Tet.Runtime.ToolsTest do
  use ExUnit.Case, async: true

  alias Tet.Runtime.Tools

  @workspace "/tmp/tet_test_facade_#{System.unique_integer([:positive])}"

  setup do
    File.mkdir_p!(@workspace)
    File.write!(Path.join(@workspace, "test.txt"), "hello world")

    on_exit(fn -> File.rm_rf!(@workspace) end)
    %{workspace: @workspace}
  end

  describe "run_tool/3" do
    test "dispatches to read tool", %{workspace: ws} do
      result = Tools.run_tool("read", %{"path" => "test.txt"}, workspace_root: ws)

      assert result.ok == true
      assert result.data.content == "hello world"
    end

    test "dispatches to list tool", %{workspace: ws} do
      result = Tools.run_tool("list", %{"path" => "."}, workspace_root: ws)

      assert result.ok == true
      assert length(result.data.entries) >= 1
    end

    test "dispatches to search tool", %{workspace: ws} do
      result = Tools.run_tool("search", %{"path" => ".", "query" => "hello"}, workspace_root: ws)

      assert result.ok == true
      assert result.data.summary.match_count >= 1
    end

    test "returns error for unknown tool" do
      result = Tools.run_tool("delete", %{}, workspace_root: "/tmp")

      assert result.ok == false
      assert result.error.code == "tool_unavailable"
    end

    test "known_tool_names returns implemented tools" do
      names = Tools.known_tool_names()
      assert "read" in names
      assert "list" in names
      assert "search" in names
    end
  end
end
