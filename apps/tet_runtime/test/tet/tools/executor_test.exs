defmodule Tet.Runtime.Tools.ExecutorTest do
  use ExUnit.Case, async: true

  alias Tet.Runtime.Tools.Executor

  @workspace_root System.tmp_dir!()

  describe "known_tools/0" do
    test "returns all four registered tools" do
      tools = Executor.known_tools()

      assert "read" in tools
      assert "list" in tools
      assert "search" in tools
      assert "patch" in tools
      assert length(tools) == 4
    end
  end

  describe "known_tool?/1" do
    test "recognizes registered tools" do
      assert Executor.known_tool?("read")
      assert Executor.known_tool?("list")
      assert Executor.known_tool?("search")
      assert Executor.known_tool?("patch")
    end

    test "rejects unknown tools" do
      refute Executor.known_tool?("nonexistent")
      refute Executor.known_tool?("rm")
      refute Executor.known_tool?("")
    end
  end

  describe "read_only?/1" do
    test "read-only tools return true" do
      assert Executor.read_only?("read")
      assert Executor.read_only?("list")
      assert Executor.read_only?("search")
    end

    test "write tools return false" do
      refute Executor.read_only?("patch")
    end

    test "unknown tools return false" do
      refute Executor.read_only?("nonexistent")
    end
  end

  describe "execute/2" do
    test "executes read tool against a real file" do
      path =
        Path.join(
          @workspace_root,
          "executor_test_#{System.unique_integer([:positive])}.txt"
        )

      File.write!(path, "hello from executor test\nline two\n")

      on_exit(fn -> File.rm(path) end)

      tool_call = %{
        name: "read",
        id: "call_test_read",
        arguments: %{"path" => Path.basename(path)},
        index: 0
      }

      assert {:ok, result} = Executor.execute(tool_call, workspace_root: @workspace_root)
      assert result.tool_call_id == "call_test_read"
      assert is_binary(result.content)

      decoded = :json.decode(result.content)
      assert decoded["ok"] == true
      assert is_map(decoded["data"])
      assert decoded["data"]["content"] =~ "hello from executor test"
    end

    test "executes list tool against a temp directory" do
      tool_call = %{
        name: "list",
        id: "call_test_list",
        arguments: %{"path" => "."},
        index: 0
      }

      assert {:ok, result} = Executor.execute(tool_call, workspace_root: @workspace_root)
      assert result.tool_call_id == "call_test_list"

      decoded = :json.decode(result.content)
      assert decoded["ok"] == true
      assert is_map(decoded["data"])
    end

    test "returns error envelope for unknown tool" do
      tool_call = %{
        name: "nonexistent_tool",
        id: "call_test_unknown",
        arguments: %{},
        index: 0
      }

      assert {:ok, result} = Executor.execute(tool_call, workspace_root: @workspace_root)

      decoded = :json.decode(result.content)
      assert decoded["ok"] == false
      assert decoded["error"]["code"] == "tool_unavailable"
    end

    test "read on nonexistent file returns error envelope without crashing" do
      tool_call = %{
        name: "read",
        id: "call_test_error",
        arguments: %{"path" => "nonexistent_file_xyz.txt"},
        index: 0
      }

      assert {:ok, result} = Executor.execute(tool_call, workspace_root: @workspace_root)
      assert is_binary(result.content)
      assert result.tool_call_id == "call_test_error"

      decoded = :json.decode(result.content)
      assert decoded["ok"] == false
      assert is_map(decoded["error"])
    end

    test "accepts string-keyed tool call maps" do
      tool_call = %{
        "name" => "list",
        "id" => "call_test_string_keys",
        "arguments" => %{"path" => "."}
      }

      assert {:ok, result} = Executor.execute(tool_call, workspace_root: @workspace_root)
      assert result.tool_call_id == "call_test_string_keys"

      decoded = :json.decode(result.content)
      assert decoded["ok"] == true
    end

    test "always returns {:ok, _} even on tool errors" do
      tool_call = %{
        name: "read",
        id: "call_always_ok",
        arguments: %{"path" => "/no/such/path/ever"},
        index: 0
      }

      # The tuple shape is always {:ok, _} — errors live in the JSON content
      assert {:ok, result} = Executor.execute(tool_call, workspace_root: @workspace_root)
      assert is_binary(result.content)
    end

    test "persists ToolRun when store is configured" do
      # Agent-backed mock store that records calls
      {:ok, store_agent} = Agent.start_link(fn -> [] end)

      defmodule TestStore do
        def record_tool_run(attrs), do: Agent.update(:test_store_agent, &[attrs | &1])
      end

      # Stash the agent pid where the mock can reach it
      Process.register(store_agent, :test_store_agent)

      tool_call = %{
        name: "read",
        id: "call_persist_test",
        arguments: %{"path" => "."},
        index: 0
      }

      assert {:ok, _result} =
               Executor.execute(tool_call,
                 workspace_root: @workspace_root,
                 session_id: "sess_123",
                 store: TestStore
               )

      [recorded] = Agent.get(store_agent, & &1)
      assert recorded.id == "call_persist_test"
      assert recorded.session_id == "sess_123"
      assert recorded.tool_name == "read"
      assert recorded.read_or_write == :read

      Agent.stop(store_agent)

      # Process.unregister may fail if Agent.stop already cleaned up;
      # that's fine — the process is gone either way.
      try do
        Process.unregister(:test_store_agent)
      rescue
        ArgumentError -> :ok
      end
    end
  end
end
