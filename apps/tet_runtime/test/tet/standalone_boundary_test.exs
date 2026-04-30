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

  test "Tet facade doctor reports the standalone-only application boundary" do
    assert {:ok, report} = Tet.doctor()

    assert report.profile == :tet_standalone
    assert report.applications == [:tet_core, :tet_store_sqlite, :tet_runtime, :tet_cli]
    assert report.core.application == :tet_core
    assert report.runtime.application == :tet_runtime
    assert report.store.application in [:tet_store_sqlite, :none]
    assert :ok = Boundary.validate_standalone_applications(report.applications)
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
end
