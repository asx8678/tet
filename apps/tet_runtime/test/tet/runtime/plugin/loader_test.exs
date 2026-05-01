defmodule Tet.Runtime.Plugin.LoaderTest do
  use ExUnit.Case, async: false

  alias Tet.Plugin.Manifest
  alias Tet.Runtime.Plugin.Loader

  # Test plugin module referenced by manifests
  defmodule TestPlugin do
    @behaviour Tet.Plugin.Behaviour

    def handle_tool_call(_manifest, _args), do: {:ok, "tool_result"}
    def handle_file_access(_manifest, _args), do: {:ok, "file_result"}
  end

  setup do
    # Store original env to restore after test
    original = Application.get_env(:tet_runtime, :plugin_dirs)

    on_exit(fn ->
      if original do
        Application.put_env(:tet_runtime, :plugin_dirs, original)
      else
        Application.delete_env(:tet_runtime, :plugin_dirs)
      end
    end)

    %{original: original}
  end

  describe "discover/0" do
    test "returns empty list when no plugin directories exist" do
      Application.put_env(:tet_runtime, :plugin_dirs, [
        "/tmp/tet_nonexistent_plugins_#{:erlang.unique_integer()}"
      ])

      assert Loader.discover() == []
    end

    test "discovers valid plugin manifests" do
      dir = create_temp_plugin_dir()

      write_manifest(dir, "test-plugin", %{
        "name" => "test-plugin",
        "version" => "1.0.0",
        "capabilities" => ["tool_execution"],
        "trust_level" => "sandboxed",
        "entrypoint" => "Elixir.Tet.Runtime.Plugin.LoaderTest.TestPlugin"
      })

      Application.put_env(:tet_runtime, :plugin_dirs, [dir])

      results = Loader.discover()
      assert length(results) == 1
      assert {:ok, %Manifest{name: "test-plugin"}} = hd(results)

      File.rm_rf!(dir)
    end

    test "skips directories without manifest.json" do
      dir = create_temp_plugin_dir()
      File.mkdir_p(Path.join(dir, "empty-plugin"))

      Application.put_env(:tet_runtime, :plugin_dirs, [dir])

      assert Loader.discover() == []

      File.rm_rf!(dir)
    end

    test "returns error for invalid JSON" do
      dir = create_temp_plugin_dir()

      plugin_dir = Path.join(dir, "bad-json")
      File.mkdir_p!(plugin_dir)
      File.write!(Path.join(plugin_dir, "manifest.json"), "not valid json{{{\"")

      Application.put_env(:tet_runtime, :plugin_dirs, [dir])

      results = Loader.discover()
      assert length(results) == 1
      assert {:error, {:invalid_json, _, _}} = hd(results)

      File.rm_rf!(dir)
    end

    test "returns error for valid JSON but invalid manifest" do
      dir = create_temp_plugin_dir()

      write_manifest(dir, "bad-manifest", %{
        "name" => "",
        "version" => "1.0.0",
        "capabilities" => ["tool_execution"],
        "trust_level" => "sandboxed",
        "entrypoint" => "Elixir.Tet.Runtime.Plugin.LoaderTest.TestPlugin"
      })

      Application.put_env(:tet_runtime, :plugin_dirs, [dir])

      results = Loader.discover()
      assert length(results) == 1
      assert {:error, :invalid_name} = hd(results)

      File.rm_rf!(dir)
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
        "entrypoint" => "Elixir.Tet.Runtime.Plugin.LoaderTest.TestPlugin"
      })

      Application.put_env(:tet_runtime, :plugin_dirs, [dir])

      assert {:ok, %Manifest{name: "target-plugin", version: "2.0.0"}} =
               Loader.load("target-plugin")

      File.rm_rf!(dir)
    end

    test "returns error for unknown plugin" do
      Application.put_env(:tet_runtime, :plugin_dirs, [
        "/tmp/tet_nonexistent_#{:erlang.unique_integer()}"
      ])

      assert {:error, {:plugin_not_found, "no-such-plugin"}} = Loader.load("no-such-plugin")
    end

    test "rejects path traversal attempts with invalid_plugin_name error" do
      dir = create_temp_plugin_dir()

      Application.put_env(:tet_runtime, :plugin_dirs, [dir])

      assert {:error, {:invalid_plugin_name, "../outside/escape"}} =
               Loader.load("../outside/escape")

      assert {:error, {:invalid_plugin_name, "sub/../escape"}} = Loader.load("sub/../escape")

      File.rm_rf!(dir)
    end

    test "rejects names with slashes, backslashes, and absolute paths" do
      dir = create_temp_plugin_dir()
      Application.put_env(:tet_runtime, :plugin_dirs, [dir])

      assert {:error, {:invalid_plugin_name, "foo/bar"}} = Loader.load("foo/bar")
      assert {:error, {:invalid_plugin_name, "foo\\bar"}} = Loader.load("foo\\bar")
      assert {:error, {:invalid_plugin_name, "/etc/passwd"}} = Loader.load("/etc/passwd")
      assert {:error, {:invalid_plugin_name, ".."}} = Loader.load("..")

      File.rm_rf!(dir)
    end

    test "real outside-target plugin is not loaded even if it exists on filesystem" do
      dir = create_temp_plugin_dir()

      # Create a manifest OUTSIDE the configured plugin directory
      outside_dir = create_temp_plugin_dir()

      write_manifest(outside_dir, "escape-plugin", %{
        "name" => "escape-plugin",
        "version" => "1.0.0",
        "capabilities" => ["tool_execution"],
        "trust_level" => "sandboxed",
        "entrypoint" => "Elixir.Tet.Runtime.Plugin.LoaderTest.TestPlugin"
      })

      Application.put_env(:tet_runtime, :plugin_dirs, [dir])

      # A name that references the outside dir via relative path should be rejected
      assert {:error, {:invalid_plugin_name, _}} = Loader.load("../escape-plugin")

      # The outside dir itself should NOT be discoverable
      results = Loader.discover()
      assert results == []

      File.rm_rf!(dir)
      File.rm_rf!(outside_dir)
    end
  end

  # -- Helpers --

  defp create_temp_plugin_dir do
    dir = Path.join(System.tmp_dir!(), "tet_runtime_plugins_test_#{:erlang.unique_integer()}")
    File.mkdir_p!(dir)
    dir
  end

  defp write_manifest(base_dir, plugin_name, data) do
    plugin_dir = Path.join(base_dir, plugin_name)
    File.mkdir_p!(plugin_dir)
    File.write!(Path.join(plugin_dir, "manifest.json"), Jason.encode!(data))
  end
end
