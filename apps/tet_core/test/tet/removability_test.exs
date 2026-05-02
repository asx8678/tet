defmodule Tet.RemovabilityTest do
  use ExUnit.Case, async: true

  alias Tet.Removability

  describe "web_deps/0" do
    test "returns the known web/Phoenix dependency atoms" do
      assert Removability.web_deps() == [
               :bandit,
               :cowboy,
               :cowlib,
               :phoenix,
               :phoenix_ecto,
               :phoenix_html,
               :phoenix_live_dashboard,
               :phoenix_live_view,
               :phoenix_pubsub,
               :plug,
               :plug_cowboy,
               :ranch,
               :thousand_island,
               :websock,
               :websock_adapter
             ]
    end
  end

  describe "standalone_apps/0" do
    test "returns the list of standalone app atoms" do
      assert Removability.standalone_apps() == [
               :tet_core,
               :tet_runtime,
               :tet_cli,
               :tet_store_sqlite
             ]
    end
  end

  describe "web_apps/0" do
    test "returns the list of web app atoms" do
      assert Removability.web_apps() == [:tet_web_phoenix]
    end
  end

  describe "check_standalone_deps/1" do
    test "returns {:ok, []} when the deps list is empty" do
      assert {:ok, []} = Removability.check_standalone_deps([])
    end

    test "returns {:ok, []} when no web deps are present" do
      deps = [
        {:jason, "~> 1.0"},
        {:tet_core, in_umbrella: true},
        {:ecto_sql, "~> 3.11"},
        {:exqlite, "~> 0.1"}
      ]

      assert {:ok, []} = Removability.check_standalone_deps(deps)
    end

    test "returns {:error, violations} with a single web dep" do
      deps = [{:jason, "~> 1.0"}, {:phoenix, "~> 1.7"}]

      assert {:error, [:phoenix]} = Removability.check_standalone_deps(deps)
    end

    test "returns {:error, violations} with multiple web deps mixed in" do
      deps = [
        {:jason, "~> 1.0"},
        {:phoenix, "~> 1.7"},
        {:tet_core, in_umbrella: true},
        {:plug_cowboy, "~> 2.0"},
        {:bandit, "~> 1.0"}
      ]

      assert {:error, [:phoenix, :plug_cowboy, :bandit]} =
               Removability.check_standalone_deps(deps)
    end

    test "detects all known web deps when they are all present" do
      web = Removability.web_deps()
      deps = Enum.map(web, fn dep -> {dep, "~> 1.0"} end)

      assert {:error, ^web} = Removability.check_standalone_deps(deps)
    end

    test "handles 3-tuple dependency specs like {:phoenix, \"~> 1.7\", only: :dev}" do
      deps = [
        {:jason, "~> 1.0"},
        {:phoenix, "~> 1.7", only: :dev},
        {:plug, "~> 1.15", only: [:dev, :test]}
      ]

      assert {:error, [:phoenix, :plug]} = Removability.check_standalone_deps(deps)
    end

    test "detects all web deps in 3-tuple form" do
      web = Removability.web_deps()
      deps = Enum.map(web, fn dep -> {dep, "~> 1.0", only: :dev} end)

      assert {:error, ^web} = Removability.check_standalone_deps(deps)
    end

    test "catches prefix-matched web deps like :phoenix_live_reload" do
      deps = [{:jason, "~> 1.0"}, {:phoenix_live_reload, "~> 1.4"}]

      assert {:error, [:phoenix_live_reload]} = Removability.check_standalone_deps(deps)
    end

    test "catches prefix-matched web deps like :plug_crypto" do
      deps = [{:ecto, "~> 3.11"}, {:plug_crypto, "~> 2.0"}]

      assert {:error, [:plug_crypto]} = Removability.check_standalone_deps(deps)
    end
  end

  describe "check_no_compile_dependency/2 with real project deps" do
    test "tet_core does not require :phoenix" do
      assert Removability.check_no_compile_dependency(:tet_core, :phoenix)
    end

    test "tet_core does not require any web dep" do
      for dep <- Removability.web_deps() do
        assert Removability.check_no_compile_dependency(:tet_core, dep),
               "tet_core should not depend on #{dep}"
      end
    end

    test "tet_runtime does not require :phoenix" do
      assert Removability.check_no_compile_dependency(:tet_runtime, :phoenix)
    end

    test "tet_runtime does not require any web dep" do
      for dep <- Removability.web_deps() do
        assert Removability.check_no_compile_dependency(:tet_runtime, dep),
               "tet_runtime should not depend on #{dep}"
      end
    end

    test "tet_cli does not require :phoenix" do
      assert Removability.check_no_compile_dependency(:tet_cli, :phoenix)
    end

    test "tet_cli does not require any web dep" do
      for dep <- Removability.web_deps() do
        assert Removability.check_no_compile_dependency(:tet_cli, dep),
               "tet_cli should not depend on #{dep}"
      end
    end

    test "tet_store_memory does not require :phoenix" do
      assert Removability.check_no_compile_dependency(:tet_store_memory, :phoenix)
    end

    test "tet_store_memory does not require any web dep" do
      for dep <- Removability.web_deps() do
        assert Removability.check_no_compile_dependency(:tet_store_memory, dep),
               "tet_store_memory should not depend on #{dep}"
      end
    end

    test "tet_store_sqlite does not require :phoenix" do
      assert Removability.check_no_compile_dependency(:tet_store_sqlite, :phoenix)
    end

    test "tet_store_sqlite does not require any web dep" do
      for dep <- Removability.web_deps() do
        assert Removability.check_no_compile_dependency(:tet_store_sqlite, dep),
               "tet_store_sqlite should not depend on #{dep}"
      end
    end

    test "the web app IS the only one that needs Phoenix (standalone apps check)" do
      # Every standalone app must be Phoenix-free
      for app <- Removability.standalone_apps() do
        assert Removability.check_no_compile_dependency(app, :phoenix),
               "#{app} should not depend on :phoenix"
      end
    end

    test "no standalone app depends on any web dep" do
      for app <- Removability.standalone_apps(), dep <- Removability.web_deps() do
        assert Removability.check_no_compile_dependency(app, dep),
               "#{app} should not depend on #{dep}"
      end
    end
  end

  describe "deps_for_app/1" do
    test "tet_core deps includes :jason but not :phoenix" do
      deps = Removability.deps_for_app(:tet_core)
      dep_names = Enum.map(deps, fn {name, _opts} -> name end)

      assert :jason in dep_names
      refute :phoenix in dep_names
    end

    test "tet_cli deps includes tet_core and tet_runtime" do
      deps = Removability.deps_for_app(:tet_cli)
      dep_names = Enum.map(deps, fn {name, _opts} -> name end)

      assert :tet_core in dep_names
      assert :tet_runtime in dep_names
    end

    test "tet_runtime deps includes tet_core and jason" do
      deps = Removability.deps_for_app(:tet_runtime)
      dep_names = Enum.map(deps, fn {name, _opts} -> name end)

      assert :tet_core in dep_names
      assert :jason in dep_names
    end

    test "tet_store_memory deps includes tet_core" do
      deps = Removability.deps_for_app(:tet_store_memory)
      dep_names = Enum.map(deps, fn {name, _opts} -> name end)

      assert :tet_core in dep_names
    end

    test "tet_store_sqlite deps includes tet_core, ecto_sql, and ecto_sqlite3" do
      deps = Removability.deps_for_app(:tet_store_sqlite)
      dep_names = Enum.map(deps, fn {name, _opts} -> name end)

      assert :tet_core in dep_names
      assert :ecto_sql in dep_names
      assert :ecto_sqlite3 in dep_names
    end

    test "tet_web_phoenix deps are readable when present, empty when absent" do
      if Code.ensure_loaded?(TetWebPhoenix.MixProject) do
        deps = Removability.deps_for_app(:tet_web_phoenix)
        dep_names = Enum.map(deps, &elem(&1, 0))
        assert :tet_core in dep_names
        assert :tet_runtime in dep_names
      else
        assert Removability.deps_for_app(:tet_web_phoenix) == []
      end
    end

    test "unknown app returns empty list" do
      assert Removability.deps_for_app(:nonexistent) == []
    end

    test "returns empty list when MixProject module is not loaded (e.g. after teardown)" do
      # Simulate the safe behaviour: nil/unknown module => []
      assert Removability.deps_for_app(:non_existent_app) == []
    end
  end
end
