defmodule Tet.ProfileRegistryLoaderTest do
  use ExUnit.Case, async: false

  alias Tet.Runtime.ProfileRegistry, as: RuntimeProfileRegistry

  setup do
    old_env = System.get_env("TET_PROFILE_REGISTRY_PATH")
    System.delete_env("TET_PROFILE_REGISTRY_PATH")

    old_model_env = System.get_env("TET_MODEL_REGISTRY_PATH")
    System.delete_env("TET_MODEL_REGISTRY_PATH")

    old_app_path = Application.get_env(:tet_runtime, :profile_registry_path)
    Application.delete_env(:tet_runtime, :profile_registry_path)

    old_model_app_path = Application.get_env(:tet_runtime, :model_registry_path)
    Application.delete_env(:tet_runtime, :model_registry_path)

    tmp_root = unique_tmp_root("tet-profile-registry-test")
    File.rm_rf!(tmp_root)
    File.mkdir_p!(tmp_root)

    on_exit(fn ->
      restore_env("TET_PROFILE_REGISTRY_PATH", old_env)
      restore_env("TET_MODEL_REGISTRY_PATH", old_model_env)
      restore_app_env(:tet_runtime, :profile_registry_path, old_app_path)
      restore_app_env(:tet_runtime, :model_registry_path, old_model_app_path)
      File.rm_rf!(tmp_root)
    end)

    {:ok, tmp_root: tmp_root}
  end

  test "loads bundled default profiles and validates model references" do
    assert {:ok, registry} = RuntimeProfileRegistry.load()

    assert Map.has_key?(registry.profiles, "tet_standalone")
    assert Map.has_key?(registry.profiles, "chat")
    assert registry.profiles["chat"].overlays.model.default_model == "openai/gpt-4o-mini"

    assert {:ok, profiles} = RuntimeProfileRegistry.list()
    assert Enum.map(profiles, & &1.id) == ["chat", "tet_standalone", "tool_use"]

    assert {:ok, tool_use} = Tet.get_profile("tool_use")
    assert tool_use.overlays.tool.mode == "standard"
    assert tool_use.overlays.cache.policy == "drop"
  end

  test "loads editable registry data from an explicit path", %{tmp_root: tmp_root} do
    path = Path.join(tmp_root, "profiles.json")
    File.write!(path, File.read!(RuntimeProfileRegistry.path()))

    assert {:ok, registry} = RuntimeProfileRegistry.load(profile_registry_path: path)

    assert registry.profiles["tet_standalone"].overlays.model.default_model == "mock/default"
  end

  test "path resolution honors env and app config before bundled defaults", %{tmp_root: tmp_root} do
    env_path = Path.join(tmp_root, "env-profiles.json")
    app_path = Path.join(tmp_root, "app-profiles.json")

    Application.put_env(:tet_runtime, :profile_registry_path, app_path)
    assert RuntimeProfileRegistry.path() == app_path

    System.put_env("TET_PROFILE_REGISTRY_PATH", env_path)
    assert RuntimeProfileRegistry.path() == env_path
    assert RuntimeProfileRegistry.path(profile_registry_path: "explicit.json") == "explicit.json"
  end

  test "unreadable registries return structured errors", %{tmp_root: tmp_root} do
    missing_path = Path.join(tmp_root, "missing.json")

    assert {:error, [error]} = RuntimeProfileRegistry.load(profile_registry_path: missing_path)

    assert error.path == []
    assert error.code == :registry_unreadable
    assert error.details.path == missing_path
    assert error.details.reason == :enoent
  end

  test "diagnose summarizes invalid editable registry errors", %{tmp_root: tmp_root} do
    path = Path.join(tmp_root, "invalid.json")
    File.write!(path, ~s({"schema_version":1,"profiles":{}}))

    assert {:error, report} = RuntimeProfileRegistry.diagnose(profile_registry_path: path)

    assert report.status == :error
    assert report.path == path
    assert report.message =~ "profile registry invalid"
    assert Enum.any?(report.errors, &(&1.path == ["profiles"] and &1.code == :invalid_value))
  end

  test "model reference validation uses the configured model registry", %{tmp_root: tmp_root} do
    path = Path.join(tmp_root, "profiles-bad-model.json")

    bad_registry =
      RuntimeProfileRegistry.path()
      |> File.read!()
      |> String.replace("openai/gpt-4o-mini", "missing/model")

    File.write!(path, bad_registry)

    assert {:error, errors} = RuntimeProfileRegistry.load(profile_registry_path: path)

    assert Enum.any?(
             errors,
             &(&1.code == :unknown_reference and &1.details.reference == "missing/model")
           )
  end

  test "public facade lists and inspects profiles" do
    assert {:ok, profiles} = Tet.list_profiles()
    assert Enum.any?(profiles, &(&1.id == "chat" and &1.default_model == "openai/gpt-4o-mini"))

    assert {:ok, profile} = Tet.get_profile(:chat)
    assert profile.overlays.prompt.system =~ "Tet"

    assert {:error, :profile_not_found} = Tet.get_profile("missing")
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
