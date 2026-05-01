defmodule Tet.Mcp.ToolAdapterTest do
  use ExUnit.Case, async: true

  alias Tet.Mcp.ToolAdapter

  describe "namespaced_name/2" do
    test "produces the mcp-prefixed three-part name" do
      assert ToolAdapter.namespaced_name("fs", "read_file") == "mcp:fs:read_file"
    end

    test "handles multi-word server ids and tool names" do
      assert ToolAdapter.namespaced_name("file-server", "search_index") ==
               "mcp:file-server:search_index"
    end

    test "rejects colon in server_id" do
      assert {:error, {:colon_in_field, :server_id}} =
               ToolAdapter.namespaced_name("bad:id", "read_file")
    end

    test "rejects colon in tool_name" do
      assert {:error, {:colon_in_field, :tool_name}} =
               ToolAdapter.namespaced_name("fs", "bad:name")
    end

    test "rejects empty server_id" do
      assert {:error, {:empty_field, :server_id}} = ToolAdapter.namespaced_name("", "read_file")
    end

    test "rejects empty tool_name" do
      assert {:error, {:empty_field, :tool_name}} = ToolAdapter.namespaced_name("fs", "")
    end

    test "rejects non-binary args" do
      assert {:error, :invalid_args} = ToolAdapter.namespaced_name(123, "read")
      assert {:error, :invalid_args} = ToolAdapter.namespaced_name("fs", :read)
    end
  end

  describe "to_tool/3" do
    test "converts a minimal descriptor" do
      descriptor = %{"name" => "read_file", "description" => "Read a file"}

      assert {:ok, tool} = ToolAdapter.to_tool("fs", descriptor)
      assert tool.name == "mcp:fs:read_file"
      assert tool.server_id == "fs"
      assert tool.original_name == "read_file"
      assert tool.description == "Read a file"
    end

    test "classifies the tool via heuristic" do
      descriptor = %{"name" => "read_file"}

      assert {:ok, tool} = ToolAdapter.to_tool("fs", descriptor)
      assert tool.classification == :read
    end

    test "classifies write tools" do
      descriptor = %{"name" => "create_file"}

      assert {:ok, tool} = ToolAdapter.to_tool("fs", descriptor)
      assert tool.classification == :write
    end

    test "classifies shell tools" do
      descriptor = %{"name" => "exec_bash"}

      assert {:ok, tool} = ToolAdapter.to_tool("fs", descriptor)
      assert tool.classification == :shell
    end

    test "uses inputSchema from descriptor" do
      schema = %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}}
      descriptor = %{"name" => "read_file", "inputSchema" => schema}

      assert {:ok, tool} = ToolAdapter.to_tool("fs", descriptor)
      assert tool.input_schema == schema
    end

    test "accepts mcp_category that upgrades risk" do
      descriptor = %{"name" => "read_file", "mcp_category" => :admin}

      assert {:ok, tool} = ToolAdapter.to_tool("fs", descriptor)
      assert tool.classification == :admin
    end

    test "mcp_category cannot downgrade risk" do
      descriptor = %{"name" => "exec_bash", "mcp_category" => :read}

      assert {:ok, tool} = ToolAdapter.to_tool("fs", descriptor)
      # :shell wins over self-reported :read
      assert tool.classification == :shell
    end

    test "rejects colon in server_id" do
      descriptor = %{"name" => "read_file"}

      assert {:error, {:colon_in_field, :server_id}} =
               ToolAdapter.to_tool("bad:id", descriptor)
    end

    test "rejects colon in tool name" do
      descriptor = %{"name" => "bad:name"}

      assert {:error, {:colon_in_field, :tool_name}} =
               ToolAdapter.to_tool("fs", descriptor)
    end

    test "rejects missing name in descriptor" do
      assert {:error, :missing_name} = ToolAdapter.to_tool("fs", %{})
    end

    test "passes extra descriptor fields into annotations" do
      descriptor = %{"name" => "read_file", "custom_flag" => true}

      assert {:ok, tool} = ToolAdapter.to_tool("fs", descriptor)
      assert tool.annotations["custom_flag"] == true
    end
  end

  describe "server_id/1" do
    test "extracts server_id from namespaced name" do
      assert {:ok, "fs"} = ToolAdapter.server_id("mcp:fs:read_file")
    end

    test "rejects non-mcp name" do
      assert {:error, :invalid_namespace_format} = ToolAdapter.server_id("custom:fs:read_file")
    end

    test "rejects malformed name" do
      assert {:error, :invalid_namespace_format} = ToolAdapter.server_id("mcp:only_one_part")
    end

    test "rejects non-binary" do
      assert {:error, :invalid_name} = ToolAdapter.server_id(123)
    end
  end

  describe "original_name/1" do
    test "extracts original_name from namespaced name" do
      assert {:ok, "read_file"} = ToolAdapter.original_name("mcp:fs:read_file")
    end

    test "rejects non-mcp name" do
      assert {:error, :invalid_namespace_format} =
               ToolAdapter.original_name("custom:fs:read_file")
    end
  end

  describe "mcp_tool_name?/1" do
    test "returns true for valid mcp namespaced names" do
      assert ToolAdapter.mcp_tool_name?("mcp:fs:read_file") == true
      assert ToolAdapter.mcp_tool_name?("mcp:git-server:log") == true
    end

    test "returns false for non-mcp prefix" do
      assert ToolAdapter.mcp_tool_name?("custom:fs:read_file") == false
    end

    test "returns false for plain name" do
      assert ToolAdapter.mcp_tool_name?("read_file") == false
    end

    test "returns false for missing parts" do
      assert ToolAdapter.mcp_tool_name?("mcp:only_one") == false
      assert ToolAdapter.mcp_tool_name?("mcp::tool") == false
    end

    test "returns false for non-binary" do
      assert ToolAdapter.mcp_tool_name?(123) == false
      assert ToolAdapter.mcp_tool_name?(nil) == false
    end
  end

  describe "round-trip namespace parsing" do
    test "namespaced_name → server_id + original_name round-trips" do
      server_ids = ["fs", "git", "db", "file-server"]
      tool_names = ["read_file", "exec_bash", "search_index", "create_record"]

      for sid <- server_ids, tn <- tool_names do
        namespaced = ToolAdapter.namespaced_name(sid, tn)
        assert {:ok, ^sid} = ToolAdapter.server_id(namespaced)
        assert {:ok, ^tn} = ToolAdapter.original_name(namespaced)
      end
    end

    test "to_tool → server_id + original_name round-trips" do
      descriptor = %{"name" => "read_file", "description" => "Read a file"}
      {:ok, tool} = ToolAdapter.to_tool("fs", descriptor)

      assert {:ok, "fs"} = ToolAdapter.server_id(tool.name)
      assert {:ok, "read_file"} = ToolAdapter.original_name(tool.name)
    end
  end
end
