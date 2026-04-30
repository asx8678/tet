defmodule Tet.ModelRegistryLoaderTest do
  use ExUnit.Case, async: false

  alias Tet.Runtime.ModelRegistry, as: RuntimeModelRegistry

  setup do
    old_env = System.get_env("TET_MODEL_REGISTRY_PATH")
    System.delete_env("TET_MODEL_REGISTRY_PATH")

    old_app_path = Application.get_env(:tet_runtime, :model_registry_path)
    Application.delete_env(:tet_runtime, :model_registry_path)

    tmp_root = unique_tmp_root("tet-model-registry-test")
    File.rm_rf!(tmp_root)
    File.mkdir_p!(tmp_root)

    on_exit(fn ->
      restore_env("TET_MODEL_REGISTRY_PATH", old_env)
      restore_app_env(:tet_runtime, :model_registry_path, old_app_path)
      File.rm_rf!(tmp_root)
    end)

    {:ok, tmp_root: tmp_root}
  end

  test "loads the bundled default registry without provider or network calls" do
    assert {:ok, registry} = RuntimeModelRegistry.load()

    assert Map.has_key?(registry.providers, "mock")
    assert Map.has_key?(registry.providers, "openai_compatible")
    assert registry.profile_pins["tet_standalone"].default_model == "mock/default"

    assert {:ok, facade_registry} = Tet.model_registry()
    assert facade_registry.models["openai/gpt-4o-mini"].capabilities.tool_calls.supported
  end

  test "loads editable registry data from an explicit path", %{tmp_root: tmp_root} do
    path = Path.join(tmp_root, "models.json")
    File.write!(path, File.read!(RuntimeModelRegistry.path()))

    assert {:ok, registry} = RuntimeModelRegistry.load(model_registry_path: path)

    assert registry.models["mock/default"].capabilities.cache.supported == false
  end

  test "path resolution honors env and app config before bundled defaults", %{tmp_root: tmp_root} do
    env_path = Path.join(tmp_root, "env-models.json")
    app_path = Path.join(tmp_root, "app-models.json")

    Application.put_env(:tet_runtime, :model_registry_path, app_path)
    assert RuntimeModelRegistry.path() == app_path

    System.put_env("TET_MODEL_REGISTRY_PATH", env_path)
    assert RuntimeModelRegistry.path() == env_path
    assert RuntimeModelRegistry.path(model_registry_path: "explicit.json") == "explicit.json"
  end

  test "unreadable registries return structured errors", %{tmp_root: tmp_root} do
    missing_path = Path.join(tmp_root, "missing.json")

    assert {:error, [error]} = RuntimeModelRegistry.load(model_registry_path: missing_path)

    assert error.path == []
    assert error.code == :registry_unreadable
    assert error.details.path == missing_path
    assert error.details.reason == :enoent
  end

  test "diagnose summarizes invalid editable registry errors", %{tmp_root: tmp_root} do
    path = Path.join(tmp_root, "invalid.json")
    File.write!(path, ~s({"schema_version":1,"providers":{},"models":{},"profile_pins":{}}))

    assert {:error, report} = RuntimeModelRegistry.diagnose(model_registry_path: path)

    assert report.status == :error
    assert report.path == path
    assert report.message =~ "model registry invalid"
    assert Enum.any?(report.errors, &(&1.path == ["providers"] and &1.code == :invalid_value))
  end

  defp unique_tmp_root(prefix) do
    suffix =
      "#{System.pid()}-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"

    Path.join(System.tmp_dir!(), "#{prefix}-#{suffix}")
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)
end
