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
      assert result.data == nil
      assert result.error.code == "tool_unavailable"
      assert result.correlation == nil
      assert result.redactions == []
      assert result.truncated == false
    end

    test "known_tool_names returns implemented tools" do
      names = Tools.known_tool_names()
      assert "read" in names
      assert "list" in names
      assert "search" in names
    end
  end

  describe "envelope schema (BD-0020)" do
    test "success envelope has all required keys", %{workspace: ws} do
      result = Tools.run_tool("read", %{"path" => "test.txt"}, workspace_root: ws)

      assert Map.has_key?(result, :ok)
      assert Map.has_key?(result, :correlation)
      assert Map.has_key?(result, :data)
      assert Map.has_key?(result, :error)
      assert Map.has_key?(result, :redactions)
      assert Map.has_key?(result, :truncated)
      assert Map.has_key?(result, :limit_usage)
      assert result.ok == true
      assert result.error == nil
      assert result.redactions == []
    end

    test "error envelope has all required keys with data nil" do
      result = Tools.run_tool("read", %{"path" => "../etc"}, workspace_root: "/tmp")

      assert Map.has_key?(result, :ok)
      assert Map.has_key?(result, :correlation)
      assert Map.has_key?(result, :data)
      assert Map.has_key?(result, :error)
      assert Map.has_key?(result, :redactions)
      assert Map.has_key?(result, :truncated)
      assert Map.has_key?(result, :limit_usage)
      assert result.ok == false
      assert result.data == nil
      assert result.error != nil
      assert result.redactions == []
    end

    test "unknown tool envelope has BD-0020 shape" do
      result = Tools.run_tool("delete", %{}, workspace_root: "/tmp")

      assert Map.has_key?(result, :ok)
      assert Map.has_key?(result, :correlation)
      assert Map.has_key?(result, :data)
      assert Map.has_key?(result, :error)
      assert Map.has_key?(result, :redactions)
      assert Map.has_key?(result, :truncated)
      assert Map.has_key?(result, :limit_usage)
      assert result.ok == false
      assert result.data == nil
      assert result.error.code == "tool_unavailable"
      assert result.redactions == []
      assert result.truncated == false
    end

    test "unknown tool envelope includes error.correlation" do
      result = Tools.run_tool("delete", %{}, workspace_root: "/tmp")

      assert result.ok == false

      assert Map.has_key?(result.error, :correlation),
             "error.correlation key is missing in: #{inspect(result.error)}"

      assert result.error.correlation == nil
      assert Map.has_key?(result.error, :code)
      assert Map.has_key?(result.error, :message)
      assert Map.has_key?(result.error, :kind)
      assert Map.has_key?(result.error, :retryable)
      assert Map.has_key?(result.error, :details)
    end
  end
end
