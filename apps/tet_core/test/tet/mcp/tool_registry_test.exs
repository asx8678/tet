defmodule Tet.Mcp.ToolRegistryTest do
  use ExUnit.Case, async: true

  alias Tet.Mcp.ToolRegistry

  describe "new/0" do
    test "creates an empty registry" do
      reg = ToolRegistry.new()
      assert ToolRegistry.count(reg) == 0
      assert ToolRegistry.list(reg) == []
    end
  end

  describe "new_with_builtins/1" do
    test "creates a registry with built-in tool names" do
      reg = ToolRegistry.new_with_builtins(["read_file", "write_file"])
      # Builtins are tracked but not registered as tools
      assert ToolRegistry.count(reg) == 0
    end
  end

  describe "register/3" do
    test "registers tools from a server" do
      reg = ToolRegistry.new()
      descriptors = [%{"name" => "read_file"}, %{"name" => "write_file"}]

      assert {:ok, reg} = ToolRegistry.register("fs", descriptors, reg)
      assert ToolRegistry.count(reg) == 2
      assert {:ok, _} = ToolRegistry.lookup("mcp:fs:read_file", reg)
      assert {:ok, _} = ToolRegistry.lookup("mcp:fs:write_file", reg)
    end

    test "re-registration overwrites existing tool (last-write-wins)" do
      reg = ToolRegistry.new()
      desc1 = [%{"name" => "read_file", "description" => "Old desc"}]
      desc2 = [%{"name" => "read_file", "description" => "New desc"}]

      {:ok, reg} = ToolRegistry.register("fs", desc1, reg)
      {:ok, reg} = ToolRegistry.register("fs", desc2, reg)

      assert {:ok, tool} = ToolRegistry.lookup("mcp:fs:read_file", reg)
      assert tool.description == "New desc"
    end

    test "rejects invalid server_id with colon" do
      reg = ToolRegistry.new()
      descriptors = [%{"name" => "read_file"}]

      assert {:error, {:colon_in_field, :server_id}} =
               ToolRegistry.register("bad:id", descriptors, reg)
    end

    test "rejects tool with colon in name" do
      reg = ToolRegistry.new()
      descriptors = [%{"name" => "bad:name"}]

      assert {:error, {:colon_in_field, :tool_name}} =
               ToolRegistry.register("fs", descriptors, reg)
    end

    test "all-or-nothing: rejects entire batch if one tool is bad" do
      reg = ToolRegistry.new()

      descriptors = [
        %{"name" => "read_file"},
        %{"name" => "bad:name"}
      ]

      assert {:error, _} = ToolRegistry.register("fs", descriptors, reg)
      # No tools should have been registered
      assert ToolRegistry.count(reg) == 0
    end
  end

  describe "register_one/3" do
    test "registers a single tool" do
      reg = ToolRegistry.new()

      assert {:ok, reg} =
               ToolRegistry.register_one(
                 "fs",
                 %{"name" => "read_file", "description" => "Read"},
                 reg
               )

      assert ToolRegistry.count(reg) == 1
    end
  end

  describe "built-in shadowing rejection" do
    test "rejects MCP tool that shadows a built-in" do
      # "read_file" builtin → "tet:read_file" internally
      reg = ToolRegistry.new_with_builtins(["read_file"])
      descriptors = [%{"name" => "read_file"}]

      assert {:error, {:shadows_builtin, "mcp:fs:read_file"}} =
               ToolRegistry.register("fs", descriptors, reg)
    end

    test "allows MCP tool that does not shadow any built-in" do
      reg = ToolRegistry.new_with_builtins(["read_file"])
      descriptors = [%{"name" => "exec_bash"}]

      assert {:ok, reg} = ToolRegistry.register("fs", descriptors, reg)
      assert ToolRegistry.count(reg) == 1
    end

    test "rejects in batch when one tool shadows built-in" do
      reg = ToolRegistry.new_with_builtins(["read_file"])

      descriptors = [
        %{"name" => "search_index"},
        %{"name" => "read_file"}
      ]

      assert {:error, {:shadows_builtin, _}} = ToolRegistry.register("fs", descriptors, reg)
      # Neither tool should have been registered
      assert ToolRegistry.count(reg) == 0
    end
  end

  describe "same tool name on different servers" do
    test "allows identical original_name on different servers" do
      reg = ToolRegistry.new()

      {:ok, reg} =
        ToolRegistry.register("fs", [%{"name" => "read_file", "description" => "FS read"}], reg)

      {:ok, reg} =
        ToolRegistry.register("db", [%{"name" => "read_file", "description" => "DB read"}], reg)

      assert ToolRegistry.count(reg) == 2

      assert {:ok, fs_tool} = ToolRegistry.lookup("mcp:fs:read_file", reg)
      assert {:ok, db_tool} = ToolRegistry.lookup("mcp:db:read_file", reg)
      assert fs_tool.description == "FS read"
      assert db_tool.description == "DB read"
    end
  end

  describe "cross-server collisions" do
    test "different servers can register tools with same original name" do
      reg = ToolRegistry.new()

      {:ok, reg} = ToolRegistry.register("fs", [%{"name" => "list"}], reg)
      {:ok, reg} = ToolRegistry.register("git", [%{"name" => "list"}], reg)

      assert ToolRegistry.count(reg) == 2
      assert ToolRegistry.has_tool?("mcp:fs:list", reg)
      assert ToolRegistry.has_tool?("mcp:git:list", reg)
    end

    test "same server re-registering same tool overwrites" do
      reg = ToolRegistry.new()

      {:ok, reg} = ToolRegistry.register("fs", [%{"name" => "list", "description" => "v1"}], reg)
      {:ok, reg} = ToolRegistry.register("fs", [%{"name" => "list", "description" => "v2"}], reg)

      # Still just one tool, but updated
      assert ToolRegistry.count(reg) == 1
      assert {:ok, tool} = ToolRegistry.lookup("mcp:fs:list", reg)
      assert tool.description == "v2"
    end
  end

  describe "unregister/2" do
    test "removes a tool by namespaced name" do
      reg = ToolRegistry.new()
      {:ok, reg} = ToolRegistry.register("fs", [%{"name" => "read_file"}], reg)

      assert {:ok, reg} = ToolRegistry.unregister("mcp:fs:read_file", reg)
      assert ToolRegistry.count(reg) == 0
    end

    test "returns error for non-existent tool" do
      reg = ToolRegistry.new()
      assert {:error, :not_found} = ToolRegistry.unregister("mcp:fs:nope", reg)
    end
  end

  describe "unregister_server/2" do
    test "removes all tools belonging to a server" do
      reg = ToolRegistry.new()

      {:ok, reg} =
        ToolRegistry.register("fs", [%{"name" => "read_file"}, %{"name" => "write_file"}], reg)

      {:ok, reg} = ToolRegistry.register("db", [%{"name" => "query"}], reg)

      assert {:ok, reg} = ToolRegistry.unregister_server("fs", reg)
      assert ToolRegistry.count(reg) == 1
      assert ToolRegistry.has_tool?("mcp:db:query", reg)
      refute ToolRegistry.has_tool?("mcp:fs:read_file", reg)
    end

    test "succeeds even when server has no tools" do
      reg = ToolRegistry.new()
      assert {:ok, reg} = ToolRegistry.unregister_server("nonexistent", reg)
      assert ToolRegistry.count(reg) == 0
    end
  end

  describe "lookup/2" do
    test "finds a registered tool" do
      reg = ToolRegistry.new()
      {:ok, reg} = ToolRegistry.register("fs", [%{"name" => "read_file"}], reg)

      assert {:ok, tool} = ToolRegistry.lookup("mcp:fs:read_file", reg)
      assert tool.original_name == "read_file"
    end

    test "returns not_found for missing tool" do
      reg = ToolRegistry.new()
      assert {:error, :not_found} = ToolRegistry.lookup("mcp:fs:nope", reg)
    end
  end

  describe "has_tool?/2" do
    test "returns true for registered tool" do
      reg = ToolRegistry.new()
      {:ok, reg} = ToolRegistry.register("fs", [%{"name" => "read_file"}], reg)
      assert ToolRegistry.has_tool?("mcp:fs:read_file", reg)
    end

    test "returns false for missing tool" do
      reg = ToolRegistry.new()
      refute ToolRegistry.has_tool?("mcp:fs:nope", reg)
    end
  end

  describe "list/1" do
    test "returns all tools" do
      reg = ToolRegistry.new()

      {:ok, reg} =
        ToolRegistry.register("fs", [%{"name" => "read_file"}, %{"name" => "write_file"}], reg)

      tools = ToolRegistry.list(reg)
      assert length(tools) == 2
    end
  end

  describe "count/1" do
    test "counts registered tools" do
      reg = ToolRegistry.new()
      assert ToolRegistry.count(reg) == 0

      {:ok, reg} = ToolRegistry.register("fs", [%{"name" => "read_file"}], reg)
      assert ToolRegistry.count(reg) == 1
    end
  end

  describe "conflicts/1" do
    test "returns empty list when no conflicts" do
      reg = ToolRegistry.new()
      {:ok, reg} = ToolRegistry.register("fs", [%{"name" => "read_file"}], reg)
      assert ToolRegistry.conflicts(reg) == []
    end
  end

  describe "server_tools/2" do
    test "returns tools belonging to a specific server" do
      reg = ToolRegistry.new()

      {:ok, reg} =
        ToolRegistry.register("fs", [%{"name" => "read_file"}, %{"name" => "write_file"}], reg)

      {:ok, reg} = ToolRegistry.register("db", [%{"name" => "query"}], reg)

      fs_tools = ToolRegistry.server_tools("fs", reg)
      assert length(fs_tools) == 2
      assert Enum.all?(fs_tools, &(&1.server_id == "fs"))

      db_tools = ToolRegistry.server_tools("db", reg)
      assert length(db_tools) == 1

      assert ToolRegistry.server_tools("nonexistent", reg) == []
    end
  end
end
