defmodule Tet.StandaloneBoundaryTest do
  use ExUnit.Case, async: false

  alias Tet.Runtime.Boundary

  @moduletag :standalone_boundary

  @forbidden_modules [
    Phoenix,
    Phoenix.Endpoint,
    Phoenix.LiveView,
    Phoenix.PubSub,
    Plug,
    Plug.Conn,
    Plug.Cowboy,
    :cowboy,
    :ranch,
    Bandit,
    ThousandIsland
  ]

  setup do
    tmp_root = unique_tmp_root("tet-boundary-test")
    File.rm_rf!(tmp_root)
    File.mkdir_p!(tmp_root)

    old_env =
      Map.new(["TET_PROVIDER", "TET_STORE_PATH", "TET_OPENAI_API_KEY"], fn name ->
        {name, System.get_env(name)}
      end)

    System.put_env("TET_PROVIDER", "mock")
    System.put_env("TET_STORE_PATH", Path.join(tmp_root, "messages.jsonl"))
    System.delete_env("TET_OPENAI_API_KEY")

    on_exit(fn ->
      restore_env(old_env)
      File.rm_rf!(tmp_root)
    end)

    :ok
  end

  test "Tet facade doctor reports the standalone-only application boundary" do
    assert {:ok, report} = Tet.doctor()

    assert report.status == :ok
    assert report.profile == :tet_standalone
    assert report.applications == [:tet_core, :tet_store_sqlite, :tet_runtime, :tet_cli]
    assert report.core.application == :tet_core
    assert report.runtime.application == :tet_runtime
    assert report.store.application == :tet_store_sqlite
    assert report.store.readable?
    assert report.store.writable?
    assert report.provider.provider == :mock
    assert report.release_boundary.status == :ok
    assert Enum.map(report.checks, & &1.name) == [:config, :store, :provider, :release_boundary]
    assert :ok = Boundary.validate_standalone_applications(report.applications)
  end

  test "doctor diagnoses selected OpenAI-compatible provider missing API key" do
    without_env("TET_OPENAI_API_KEY", fn ->
      with_env(%{"TET_PROVIDER" => "openai_compatible"}, fn ->
        assert {:ok, report} = Tet.doctor()

        assert report.status == :error
        assert report.provider.status == :error
        assert report.provider.required_env == "TET_OPENAI_API_KEY"
        assert report.provider.message =~ "OpenAI-compatible provider"

        assert Enum.any?(report.checks, fn check ->
                 check.name == :provider and check.status == :error and
                   check.message =~ "TET_OPENAI_API_KEY"
               end)
      end)
    end)
  end

  test "standalone boundary rejects known web framework and adapter apps" do
    applications = [:tet_core, :tet_web_phoenix, :phoenix, :plug_cowboy, :bandit]

    assert {:error, {:forbidden_standalone_applications, leaked}} =
             Boundary.validate_standalone_applications(applications)

    assert :tet_web_phoenix in leaked
    assert :phoenix in leaked
    assert :plug_cowboy in leaked
    assert :bandit in leaked
  end

  test "no known web framework applications are loaded or started" do
    loaded = Application.loaded_applications()
    started = Application.started_applications()

    assert Boundary.forbidden_loaded_applications(loaded) == []
    assert Boundary.forbidden_loaded_applications(started) == []
  end

  test "no known web framework modules are available in the standalone test closure" do
    leaked = for module <- @forbidden_modules, Code.ensure_loaded?(module), do: module

    assert leaked == []
  end

  defp without_env(name, fun) do
    with_env(%{name => nil}, fun)
  end

  defp with_env(vars, fun) do
    old_values = Map.new(vars, fn {name, _value} -> {name, System.get_env(name)} end)

    set_env(vars)

    try do
      fun.()
    after
      restore_env(old_values)
    end
  end

  defp set_env(vars) do
    Enum.each(vars, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)
  end

  defp restore_env(vars) do
    Enum.each(vars, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)
  end

  defp unique_tmp_root(prefix) do
    suffix =
      "#{System.pid()}-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"

    Path.join(System.tmp_dir!(), "#{prefix}-#{suffix}")
  end
end
