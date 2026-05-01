defmodule Tet.Mcp.ToolTest do
  use ExUnit.Case, async: true

  alias Tet.Mcp.Tool

  describe "new/1 with valid attrs" do
    test "accepts a valid namespaced tool" do
      attrs = %{
        name: "mcp:fs:read_file",
        server_id: "fs",
        original_name: "read_file",
        description: "Read a file"
      }

      assert {:ok, tool} = Tool.new(attrs)
      assert tool.name == "mcp:fs:read_file"
      assert tool.server_id == "fs"
      assert tool.original_name == "read_file"
      assert tool.description == "Read a file"
    end

    test "accepts atom-keyed attrs" do
      attrs = %{
        name: "mcp:git:log",
        server_id: "git",
        original_name: "log"
      }

      assert {:ok, tool} = Tool.new(attrs)
      assert tool.name == "mcp:git:log"
    end

    test "defaults classification to :write when not provided" do
      attrs = %{
        name: "mcp:fs:read_file",
        server_id: "fs",
        original_name: "read_file"
      }

      assert {:ok, tool} = Tool.new(attrs)
      assert tool.classification == :write
    end

    test "accepts explicit classification" do
      attrs = %{
        name: "mcp:fs:delete_file",
        server_id: "fs",
        original_name: "delete_file",
        classification: :admin
      }

      assert {:ok, tool} = Tool.new(attrs)
      assert tool.classification == :admin
    end

    test "defaults input_schema and annotations to empty maps" do
      attrs = %{
        name: "mcp:fs:list",
        server_id: "fs",
        original_name: "list"
      }

      assert {:ok, tool} = Tool.new(attrs)
      assert tool.input_schema == %{}
      assert tool.annotations == %{}
    end
  end

  describe "new/1 rejects colon in server_id" do
    test "rejects server_id containing colon" do
      attrs = %{
        name: "mcp:bad:id:tool",
        server_id: "bad:id",
        original_name: "tool"
      }

      assert {:error, {:colon_in_field, :server_id}} = Tool.new(attrs)
    end
  end

  describe "new/1 rejects colon in original_name" do
    test "rejects original_name containing colon" do
      attrs = %{
        name: "mcp:fs:bad:tool",
        server_id: "fs",
        original_name: "bad:tool"
      }

      assert {:error, {:colon_in_field, :original_name}} = Tool.new(attrs)
    end
  end

  describe "new/1 rejects non-mcp prefix" do
    test "rejects name without mcp: prefix" do
      attrs = %{
        name: "custom:fs:read_file",
        server_id: "fs",
        original_name: "read_file"
      }

      assert {:error, :invalid_mcp_prefix} = Tool.new(attrs)
    end

    test "rejects plain name with no prefix" do
      attrs = %{
        name: "read_file",
        server_id: "fs",
        original_name: "read_file"
      }

      assert {:error, :invalid_mcp_prefix} = Tool.new(attrs)
    end
  end

  describe "new/1 rejects mismatched components" do
    test "rejects when name does not match server_id + original_name" do
      attrs = %{
        name: "mcp:fs:read_file",
        server_id: "git",
        original_name: "read_file"
      }

      assert {:error, {:name_mismatch, _}} = Tool.new(attrs)
    end

    test "rejects when original_name component differs" do
      attrs = %{
        name: "mcp:fs:read_file",
        server_id: "fs",
        original_name: "write_file"
      }

      assert {:error, {:name_mismatch, _}} = Tool.new(attrs)
    end
  end

  describe "new/1 validates required fields" do
    test "rejects missing name" do
      assert {:error, {:missing_or_empty, :name}} =
               Tool.new(%{server_id: "fs", original_name: "read"})
    end

    test "rejects empty string name" do
      assert {:error, {:missing_or_empty, :name}} =
               Tool.new(%{name: "", server_id: "fs", original_name: "read"})
    end

    test "rejects missing server_id" do
      assert {:error, {:missing_or_empty, :server_id}} =
               Tool.new(%{name: "mcp:fs:read", original_name: "read"})
    end

    test "rejects missing original_name" do
      assert {:error, {:missing_or_empty, :original_name}} =
               Tool.new(%{name: "mcp:fs:read", server_id: "fs"})
    end

    test "rejects invalid classification" do
      attrs = %{
        name: "mcp:fs:read_file",
        server_id: "fs",
        original_name: "read_file",
        classification: :bogus
      }

      assert {:error, :invalid_classification} = Tool.new(attrs)
    end
  end

  describe "new!/1" do
    test "returns tool on success" do
      tool =
        Tool.new!(%{
          name: "mcp:fs:read_file",
          server_id: "fs",
          original_name: "read_file"
        })

      assert tool.name == "mcp:fs:read_file"
    end

    test "raises on invalid attrs" do
      assert_raise ArgumentError, ~r/invalid mcp tool/, fn ->
        Tool.new!(%{name: "bad", server_id: "fs", original_name: "x"})
      end
    end
  end

  describe "from_map/1 and to_map/1" do
    test "round-trips a tool through map serialization" do
      tool =
        Tool.new!(%{
          name: "mcp:fs:read_file",
          server_id: "fs",
          original_name: "read_file",
          description: "Read a file",
          classification: :read,
          input_schema: %{"type" => "object"},
          annotations: %{"deprecated" => false}
        })

      map = Tool.to_map(tool)
      assert {:ok, round_tripped} = Tool.from_map(map)
      assert round_tripped.name == tool.name
      assert round_tripped.server_id == tool.server_id
      assert round_tripped.original_name == tool.original_name
      assert round_tripped.description == tool.description
      assert round_tripped.classification == :read
      assert round_tripped.input_schema == tool.input_schema
    end

    test "to_map uses string keys" do
      tool =
        Tool.new!(%{
          name: "mcp:fs:list",
          server_id: "fs",
          original_name: "list"
        })

      map = Tool.to_map(tool)

      assert Map.has_key?(map, "name")
      assert Map.has_key?(map, "server_id")
      assert Map.has_key?(map, "classification")
      refute Map.has_key?(map, :name)
    end

    test "from_map rejects invalid map" do
      assert {:error, _} = Tool.from_map(%{})
      assert {:error, _} = Tool.from_map("not a map")
    end
  end
end
