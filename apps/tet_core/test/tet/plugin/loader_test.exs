defmodule Tet.Plugin.LoaderTest do
  use ExUnit.Case, async: true

  alias Tet.Plugin.{Loader, Manifest}

  # Test plugin module — simulates a real entrypoint with callback exports
  defmodule TestPlugin do
    @behaviour Tet.Plugin.Behaviour

    def handle_tool_call(_manifest, _args), do: {:ok, "tool_result"}
    def handle_file_access(_manifest, _args), do: {:ok, "file_result"}
  end

  describe "discover/0" do
    test "returns empty list when no plugin directories exist" do
      # Point at a non-existent directory
      original = Application.get_env(:tet_core, :plugin_dirs)

      Application.put_env(:tet_core, :plugin_dirs, [
        "/tmp/tet_nonexistent_plugins_#{:erlang.unique_integer()}"
      ])

      assert Loader.discover() == []

      # Restore
      if original do
        Application.put_env(:tet_core, :plugin_dirs, original)
      else
        Application.delete_env(:tet_core, :plugin_dirs)
      end
    end

    test "discovers valid plugin manifests" do
      dir = create_temp_plugin_dir()

      write_manifest(dir, "test-plugin", %{
        "name" => "test-plugin",
        "version" => "1.0.0",
        "capabilities" => ["tool_execution"],
        "trust_level" => "sandboxed",
        "entrypoint" => "Elixir.Tet.Plugin.LoaderTest.TestPlugin"
      })

      original = Application.get_env(:tet_core, :plugin_dirs)
      Application.put_env(:tet_core, :plugin_dirs, [dir])

      results = Loader.discover()
      assert length(results) == 1
      assert {:ok, %Manifest{name: "test-plugin"}} = hd(results)

      cleanup(dir, original)
    end

    test "skips directories without manifest.json" do
      dir = create_temp_plugin_dir()
      File.mkdir_p(Path.join(dir, "empty-plugin"))

      original = Application.get_env(:tet_core, :plugin_dirs)
      Application.put_env(:tet_core, :plugin_dirs, [dir])

      assert Loader.discover() == []

      cleanup(dir, original)
    end

    test "returns error for invalid JSON" do
      dir = create_temp_plugin_dir()

      plugin_dir = Path.join(dir, "bad-json")
      File.mkdir_p!(plugin_dir)
      File.write!(Path.join(plugin_dir, "manifest.json"), "not valid json{{{")

      original = Application.get_env(:tet_core, :plugin_dirs)
      Application.put_env(:tet_core, :plugin_dirs, [dir])

      results = Loader.discover()
      assert length(results) == 1
      assert {:error, {:invalid_json, _, _}} = hd(results)

      cleanup(dir, original)
    end

    test "returns error for valid JSON but invalid manifest" do
      dir = create_temp_plugin_dir()

      write_manifest(dir, "bad-manifest", %{
        "name" => "",
        "version" => "1.0.0"
      })

      original = Application.get_env(:tet_core, :plugin_dirs)
      Application.put_env(:tet_core, :plugin_dirs, [dir])

      results = Loader.discover()
      assert length(results) == 1
      assert {:error, :invalid_name} = hd(results)

      cleanup(dir, original)
    end
  end

  describe "load/1" do
    test "loads a specific plugin by name" do
      dir = create_temp_plugin_dir()

      write_manifest(dir, "target-plugin", %{
        "name" => "target-plugin",
        "version" => "2.0.0",
        "capabilities" => ["tool_execution", "file_access"],
        "trust_level" => "restricted",
        "entrypoint" => "Elixir.Tet.Plugin.LoaderTest.TestPlugin"
      })

      original = Application.get_env(:tet_core, :plugin_dirs)
      Application.put_env(:tet_core, :plugin_dirs, [dir])

      assert {:ok, %Manifest{name: "target-plugin", version: "2.0.0"}} =
               Loader.load("target-plugin")

      cleanup(dir, original)
    end

    test "returns error for unknown plugin" do
      original = Application.get_env(:tet_core, :plugin_dirs)

      Application.put_env(:tet_core, :plugin_dirs, [
        "/tmp/tet_nonexistent_#{:erlang.unique_integer()}"
      ])

      assert {:error, {:plugin_not_found, "no-such-plugin"}} = Loader.load("no-such-plugin")

      if original do
        Application.put_env(:tet_core, :plugin_dirs, original)
      else
        Application.delete_env(:tet_core, :plugin_dirs)
      end
    end
  end

  describe "validate/1" do
    test "returns :ok for plugin with loaded entrypoint and matching callbacks" do
      # Ensure TestPlugin is loaded (it is, since it's defined in this test module)
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
      # TestPlugin only implements handle_tool_call and handle_file_access,
      # not handle_network_request
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
      # Create manifest struct directly since empty caps with sandboxed is valid
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

  # -- Helpers --

  defp create_temp_plugin_dir do
    dir = Path.join(System.tmp_dir!(), "tet_plugins_test_#{:erlang.unique_integer()}")
    File.mkdir_p!(dir)
    dir
  end

  defp write_manifest(base_dir, plugin_name, data) do
    plugin_dir = Path.join(base_dir, plugin_name)
    File.mkdir_p!(plugin_dir)
    File.write!(Path.join(plugin_dir, "manifest.json"), Jason.encode!(data))
  end

  defp cleanup(dir, original_env) do
    File.rm_rf!(dir)

    if original_env do
      Application.put_env(:tet_core, :plugin_dirs, original_env)
    else
      Application.delete_env(:tet_core, :plugin_dirs)
    end
  end
end
