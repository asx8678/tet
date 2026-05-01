defmodule Tet.Plugin.LoaderTest do
  use ExUnit.Case, async: true

  alias Tet.Plugin.{Loader, Manifest}

  # Test plugin module — simulates a real entrypoint with callback exports
  defmodule TestPlugin do
    @behaviour Tet.Plugin.Behaviour

    def handle_tool_call(_manifest, _args), do: {:ok, "tool_result"}
    def handle_file_access(_manifest, _args), do: {:ok, "file_result"}
  end

  describe "validate/1" do
    test "returns :ok for plugin with loaded entrypoint and matching callbacks" do
      manifest =
        Manifest.new!(%{
          name: "valid-plugin",
          version: "1.0.0",
          capabilities: [:tool_execution, :file_access],
          trust_level: :restricted,
          entrypoint: Tet.Plugin.LoaderTest.TestPlugin
        })

      assert Loader.validate(manifest) == :ok
    end

    test "returns error when entrypoint module is not loaded" do
      manifest =
        Manifest.new!(%{
          name: "ghost-plugin",
          version: "1.0.0",
          capabilities: [:tool_execution],
          trust_level: :sandboxed,
          entrypoint: NonExistentModule12345
        })

      assert {:error, {:entrypoint_not_loaded, NonExistentModule12345}} =
               Loader.validate(manifest)
    end

    test "returns error when capability callbacks are missing" do
      manifest =
        Manifest.new!(%{
          name: "missing-callbacks",
          version: "1.0.0",
          capabilities: [:tool_execution, :network],
          trust_level: :full,
          entrypoint: Tet.Plugin.LoaderTest.TestPlugin
        })

      assert {:error, {:missing_capability_callbacks, [{:network, :handle_network_request}]}} =
               Loader.validate(manifest)
    end

    test "returns error for unknown capabilities" do
      manifest =
        Manifest.new!(%{
          name: "unknown-caps",
          version: "1.0.0",
          capabilities: [:tool_execution],
          trust_level: :sandboxed,
          entrypoint: Tet.Plugin.LoaderTest.TestPlugin
        })

      assert Loader.validate(manifest) == :ok
    end

    test "returns error for capabilities exceeding trust level" do
      # Create manifest directly to bypass validation
      manifest = %Manifest{
        name: "leaky",
        version: "1.0.0",
        capabilities: [:shell],
        trust_level: :sandboxed,
        entrypoint: Tet.Plugin.LoaderTest.TestPlugin
      }

      assert {:error, :invalid_capabilities_for_trust} = Loader.validate(manifest)
    end
  end

  describe "capabilities/1" do
    test "returns only authorized capabilities" do
      manifest =
        Manifest.new!(%{
          name: "cap-test",
          version: "1.0.0",
          capabilities: [:tool_execution, :file_access, :mcp],
          trust_level: :restricted,
          entrypoint: Tet.Plugin.LoaderTest.TestPlugin
        })

      caps = Loader.capabilities(manifest)

      assert :tool_execution in caps
      assert :file_access in caps
      assert :mcp in caps
      refute :network in caps
      refute :shell in caps
    end

    test "returns empty list for plugin with no declared capabilities" do
      manifest = %Manifest{
        name: "no-caps",
        version: "1.0.0",
        capabilities: [],
        trust_level: :sandboxed,
        entrypoint: Tet.Plugin.LoaderTest.TestPlugin
      }

      assert Loader.capabilities(manifest) == []
    end
  end
end
