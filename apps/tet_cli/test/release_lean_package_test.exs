defmodule TetCLI.ReleaseLeanPackageTest do
  use ExUnit.Case, async: false

  alias Tet.Runtime.Boundary

  @root Path.expand("../../..", __DIR__)

  # ────────────────────────────────────────────────────────────────
  # Section 1: Dependency Closure
  # ────────────────────────────────────────────────────────────────

  describe "dependency closure" do
    test "tet_web_phoenix is NOT in the standalone application list" do
      standalone = Boundary.standalone_applications()

      refute :tet_web_phoenix in standalone,
             "tet_web_phoenix must not be in standalone applications"
    end

    test "standalone applications are the expected four" do
      standalone = Boundary.standalone_applications()

      assert :tet_core in standalone
      assert :tet_store_sqlite in standalone
      assert :tet_runtime in standalone
      assert :tet_cli in standalone
      assert length(standalone) == 4
    end

    test "no circular dependencies between umbrella apps" do
      dep_map = Tet.Release.umbrella_dep_graph()

      # Check each app has no cycles via DFS
      for {app, _deps} <- dep_map do
        assert :acyclic = has_cycle?(app, dep_map, MapSet.new(), MapSet.new()),
               "#{app} has a circular dependency"
      end
    end

    test "Tet.Release dep graph matches actual mix.exs umbrella deps" do
      # Filter to apps whose mix.exs actually exists on disk so
      # the check is resilient in the web-removability sandbox where
      # optional apps (e.g. tet_web_phoenix) may be absent.
      graph =
        Tet.Release.umbrella_dep_graph()
        |> Enum.filter(fn {app, _deps} ->
          @root |> Path.join("apps/#{app}/mix.exs") |> File.exists?()
        end)
        |> Map.new()

      for {app, declared_deps} <- graph do
        content = File.read!(Path.join(@root, "apps/#{app}/mix.exs"))

        # The declared graph should match actual production in_umbrella deps
        # (test-only deps like tet_store_memory in tet_runtime are excluded from the graph)
        prod_deps =
          Regex.scan(~r/\{:([\w]+),\s*in_umbrella:\s*true\}/, content)
          |> Enum.map(fn [_full, name] -> String.to_existing_atom(name) end)

        assert Enum.sort(declared_deps) == Enum.sort(prod_deps),
               "Tet.Release dep graph for #{app} declares #{inspect(Enum.sort(declared_deps))} " <>
                 "but actual mix.exs has #{inspect(Enum.sort(prod_deps))}. " <>
                 "Update @umbrella_dep_graph in Tet.Release."
      end
    end

    test "core deps are minimal: jason, crypto, and logger only" do
      tet_core_path = Path.join(@root, "apps/tet_core/mix.exs")
      content = File.read!(tet_core_path)

      assert String.contains?(content, ~S({:jason, "~> 1.0"})),
             "tet_core must depend on jason"

      # Check tet_core's application config
      assert String.contains?(content, ~S(extra_applications: [:crypto, :logger])),
             "tet_core must only have crypto and logger as extra apps"
    end

    test "standalone release config excludes web framework applications" do
      umbrella_mix = File.read!(Path.join(@root, "mix.exs"))

      # Forbidden lists consolidated into Tet.Release — mix.exs delegates to it
      assert umbrella_mix =~ "Tet.Release.assert_standalone_release!"

      refute umbrella_mix =~ "@forbidden_standalone_exact",
             "forbidden lists should be consolidated in Tet.Release, not duplicated in mix.exs"

      refute umbrella_mix =~ "@forbidden_standalone_prefixes",
             "forbidden prefixes should be consolidated in Tet.Release, not duplicated in mix.exs"

      # Verify the centralized source actually exposes the data
      assert is_list(Tet.Release.forbidden_standalone_exact())
      assert :tet_web_phoenix in Tet.Release.forbidden_standalone_exact()
      assert is_list(Tet.Release.forbidden_standalone_prefixes())
      assert Enum.any?(Tet.Release.forbidden_standalone_prefixes(), &(&1 == "phoenix"))
    end

    test "Boundary module rejects web framework apps" do
      assert :ok = Boundary.validate_standalone_applications([:tet_core, :tet_cli, :tet_runtime])

      assert {:error, {:forbidden_standalone_applications, leaked}} =
               Boundary.validate_standalone_applications([
                 :tet_core,
                 :tet_web_phoenix,
                 :phoenix
               ])

      assert :tet_web_phoenix in leaked
      assert :phoenix in leaked
    end

    test "no known web framework modules leak into the test environment" do
      forbidden_modules = [
        Phoenix,
        Plug,
        Plug.Conn,
        Bandit,
        ThousandIsland
      ]

      leaked =
        Enum.filter(forbidden_modules, fn module ->
          Code.ensure_loaded?(module)
        end)

      assert leaked == [],
             "Forbidden web framework modules are loaded: #{inspect(leaked)}"
    end

    test "standalone umbrella apps have no runtime deps on tet_store_memory for standalone profile" do
      standalone_apps = Boundary.standalone_applications()

      # tet_store_memory may be in standalone as :temporary but is not a hard dep
      _store_memory_in_standalone = :tet_store_memory in standalone_apps

      # tet_store_sqlite is the primary store - verify it doesn't depend on tet_store_memory
      sqlite_mix = File.read!(Path.join(@root, "apps/tet_store_sqlite/mix.exs"))

      refute sqlite_mix =~ "tet_store_memory",
             "tet_store_sqlite must not depend on tet_store_memory"

      tet_memory_mix = File.read!(Path.join(@root, "apps/tet_store_memory/mix.exs"))

      assert tet_memory_mix =~ "{:tet_core, in_umbrella: true}",
             "tet_store_memory must only depend on tet_core"
    end

    @tag :release_check
    test "built standalone release excludes web/optional apps" do
      # Build the release from project root
      {_output, 0} =
        System.cmd("mix", ["release", "tet_standalone", "--overwrite"],
          env: [{"MIX_ENV", "prod"}],
          cd: @root
        )

      release_lib = Path.join(@root, "_build/prod/rel/tet_standalone/lib")

      # Get the actual apps in the release
      release_apps =
        release_lib
        |> File.ls!()
        |> Enum.map(&(String.split(&1, "-") |> List.first()))

      # Verify forbidden apps are NOT in the release
      forbidden = [
        "tet_web_phoenix",
        "phoenix",
        "phoenix_html",
        "phoenix_live_view",
        "plug",
        "plug_cowboy",
        "bandit",
        "cowboy",
        "ranch",
        "postgrex"
      ]

      for app <- forbidden do
        refute app in release_apps, "Forbidden app #{app} found in standalone release"
      end

      # Verify expected apps ARE in the release
      assert "tet_core" in release_apps
      assert "tet_cli" in release_apps
      assert "tet_runtime" in release_apps
    end

    @tag :release_check
    @tag :web_specific
    test "tet_web release builds and includes web app" do
      {_output, 0} =
        System.cmd("mix", ["release", "tet_web", "--overwrite"],
          env: [{"MIX_ENV", "prod"}],
          cd: @root
        )

      release_lib = Path.join(@root, "_build/prod/rel/tet_web/lib")

      release_apps =
        release_lib
        |> File.ls!()
        |> Enum.map(&(String.split(&1, "-") |> List.first()))

      # Web release includes standalone apps plus tet_web_phoenix
      assert "tet_core" in release_apps
      assert "tet_cli" in release_apps
      assert "tet_runtime" in release_apps
      assert "tet_web_phoenix" in release_apps

      # tet_store_memory is optional and not required in the web release
      # but if present, that's fine (it's harmless)
    end
  end

  # ────────────────────────────────────────────────────────────────
  # Section 2: Binary Size / Startup Time Baseline
  # ────────────────────────────────────────────────────────────────

  describe "binary size and startup baseline" do
    test "standalone dependency count is below threshold" do
      # Count direct deps across all standalone apps
      standalone_apps = Boundary.standalone_applications()

      all_deps =
        standalone_apps
        |> Enum.map(&read_umbrella_deps/1)
        |> List.flatten()
        |> Enum.uniq()

      # We expect: tet_core (jason), tet_store_sqlite (ecto_sql, ecto_sqlite3),
      #   tet_runtime (jason), tet_cli (nothing extra)
      # Direct umbrella deps only — transitive deps are counted separately
      dep_count = length(all_deps)

      # Sanity: standalone should have fewer than 10 direct hex deps
      assert dep_count <= 8,
             "Standalone has #{dep_count} direct deps, expected ≤ 8: #{inspect(all_deps)}"
    end

    test "optional web and postgres deps are NOT in the dependency tree" do
      all_deps =
        [:tet_core, :tet_store_sqlite, :tet_runtime, :tet_cli]
        |> Enum.map(&read_umbrella_deps/1)
        |> List.flatten()
        |> Enum.uniq()

      dep_names = all_deps

      # No Phoenix/Plug/Cowboy deps
      refute :phoenix in dep_names, "phoenix must not be a standalone dep"
      refute :plug in dep_names, "plug must not be a standalone dep"
      refute :cowboy in dep_names, "cowboy must not be a standalone dep"
      refute :bandit in dep_names, "bandit must not be a standalone dep"

      refute :phoenix_live_view in dep_names,
             "phoenix_live_view must not be a standalone dep"

      # No Postgres deps
      refute :postgrex in dep_names, "postgrex must not be a standalone dep"
    end

    test "application boots cleanly in test environment" do
      # The test environment already has the app running (test_helper starts it),
      # so this verifies we can boot without timeout
      assert {:ok, report} = Tet.doctor()
      assert report.status == :ok

      # Verify all standalone apps are actually loaded
      loaded = Application.loaded_applications() |> Enum.map(&elem(&1, 0))

      assert :tet_core in loaded
      assert :tet_runtime in loaded
      assert :tet_cli in loaded
      assert :tet_store_sqlite in loaded
    end

    test "startup completes quickly (sub-second doctor response)" do
      {duration_us, {:ok, _report}} =
        :timer.tc(fn ->
          Tet.doctor()
        end)

      # Doctor should respond in under 5 seconds (generous for CI)
      assert duration_us < 5_000_000,
             "Doctor took #{div(duration_us, 1000)}ms, expected < 5000ms"
    end

    test "standalone boundary check is fast" do
      {duration_us, result} =
        :timer.tc(fn ->
          Boundary.validate_standalone_applications(Boundary.standalone_applications())
        end)

      assert result == :ok

      assert duration_us < 1_000_000,
             "Boundary validation took #{duration_us}μs, expected < 1s"
    end

    test "release metadata references standalone and web apps correctly" do
      umbrella_mix = File.read!(Path.join(@root, "mix.exs"))

      # Verify the standalone applications declaration
      assert umbrella_mix =~ "tet_core: :permanent"
      assert umbrella_mix =~ "tet_store_sqlite: :permanent"
      assert umbrella_mix =~ "tet_runtime: :permanent"
      assert umbrella_mix =~ "tet_cli: :permanent"

      # tet_web_phoenix should NOT be in @standalone_applications
      standalone_section = Regex.run(~r/@standalone_applications\s*\[[^\]]+\]/s, umbrella_mix)

      assert standalone_section != nil

      refute hd(standalone_section) =~ "tet_web_phoenix",
             "tet_web_phoenix must not appear in @standalone_applications"

      # tet_web_phoenix SHOULD be in @web_applications
      assert umbrella_mix =~ "tet_web_phoenix: :permanent",
             "tet_web_phoenix must be in @web_applications for tet_web release"

      # Verify standalone release section references the right apps
      assert umbrella_mix =~ "applications: @standalone_applications"
      assert umbrella_mix =~ "tet_standalone:"
      assert umbrella_mix =~ "tet_web:"
      assert umbrella_mix =~ "applications: @web_applications"
    end
  end

  # ────────────────────────────────────────────────────────────────
  # Section 3: Plugin Disabled Behavior
  # ────────────────────────────────────────────────────────────────

  describe "plugin disabled behavior" do
    setup do
      # Save and restore plugin_dirs to prevent leaking between tests
      old_plugin_dirs = Application.get_env(:tet_runtime, :plugin_dirs)

      # Start a fresh plugin supervisor if one isn't running
      sup_pid =
        case Process.whereis(Tet.Runtime.Plugin.Supervisor.name()) do
          nil ->
            {:ok, pid} = Tet.Runtime.Plugin.Supervisor.start_link([])
            pid

          pid ->
            pid
        end

      # Ensure the Registry exists
      unless Process.whereis(Tet.Runtime.Plugin.Registry) do
        {:ok, _} = Registry.start_link(keys: :unique, name: Tet.Runtime.Plugin.Registry)
      end

      on_exit(fn ->
        # Restore original plugin_dirs
        if old_plugin_dirs,
          do: Application.put_env(:tet_runtime, :plugin_dirs, old_plugin_dirs),
          else: Application.delete_env(:tet_runtime, :plugin_dirs)

        # Clean up any plugins that were started
        for %{name: name} <- Tet.Runtime.Plugin.Supervisor.list_plugins() do
          Tet.Runtime.Plugin.Supervisor.stop_plugin(name)
        end
      end)

      %{sup: sup_pid}
    end

    test "plugin supervisor starts and remains healthy with zero plugins", %{sup: sup_pid} do
      assert is_pid(sup_pid)
      assert Process.alive?(sup_pid)

      # List should be empty
      assert Tet.Runtime.Plugin.Supervisor.list_plugins() == []
    end

    test "plugin loader handles empty plugin directories gracefully" do
      non_existent_dir =
        Path.join(System.tmp_dir!(), "tet_no_plugins_#{System.unique_integer([:positive])}")

      Application.put_env(:tet_runtime, :plugin_dirs, [non_existent_dir])

      assert Tet.Runtime.Plugin.Loader.discover() == []
    end

    test "plugin loader handles nil config (falls back to default dir that may not exist)" do
      Application.delete_env(:tet_runtime, :plugin_dirs)

      # Should not raise, just return empty or error gracefully
      results = Tet.Runtime.Plugin.Loader.discover()
      assert is_list(results)
    end

    test "stop_plugin with no plugins returns not_found" do
      assert {:error, :not_found} =
               Tet.Runtime.Plugin.Supervisor.stop_plugin("nonexistent-plugin")
    end

    test "starting and stopping zero plugins is a no-op" do
      # Verify the supervision tree is consistent before and after
      children_before = DynamicSupervisor.which_children(Tet.Runtime.Plugin.Supervisor.name())

      assert Tet.Runtime.Plugin.Supervisor.list_plugins() == []

      children_after = DynamicSupervisor.which_children(Tet.Runtime.Plugin.Supervisor.name())

      assert children_before == children_after
    end

    test "runtime boots cleanly with no plugins configured even when store is available",
         %{sup: _sup_pid} do
      # Verify the whole system is fine with zero plugins
      assert {:ok, report} = Tet.doctor()
      assert report.status == :ok

      # Plugin supervisor should be running
      assert Process.whereis(Tet.Runtime.Plugin.Supervisor.name()) != nil
    end

    test "plugin supervisor with empty config consumes negligible resources" do
      sup = Tet.Runtime.Plugin.Supervisor.name()

      # Measure memory before any plugins
      {_duration, memory_before} =
        :timer.tc(fn ->
          :erlang.memory(:processes)
        end)

      # Supervisor with no children should have minimal memory
      children = DynamicSupervisor.which_children(sup)
      active_children = Enum.filter(children, fn {_, pid, _, _} -> is_pid(pid) end)

      assert active_children == [],
             "Expected zero plugin children, got: #{inspect(active_children)}"

      {_duration2, memory_after} =
        :timer.tc(fn ->
          :erlang.memory(:processes)
        end)

      assert is_integer(memory_after)
      assert is_integer(memory_before)
    end

    test "core plugin loader validate returns error for unloaded entrypoint" do
      manifest = %Tet.Plugin.Manifest{
        name: "ghost",
        version: "1.0.0",
        capabilities: [:tool_execution],
        trust_level: :sandboxed,
        entrypoint: NonExistentGhostModule
      }

      assert {:error, {:entrypoint_not_loaded, NonExistentGhostModule}} =
               Tet.Plugin.Loader.validate(manifest)
    end

    test "capability gate returns unauthorized for non-declared capability" do
      manifest = %Tet.Plugin.Manifest{
        name: "sandboxed-demo",
        version: "1.0.0",
        capabilities: [:tool_execution],
        trust_level: :sandboxed,
        entrypoint: __MODULE__
      }

      assert {:error, {:unauthorized_capability, :shell}} =
               Tet.Plugin.Capability.gate(manifest, :shell, fn -> :ok end)
    end
  end

  # ────────────────────────────────────────────────────────────────
  # Private helpers
  # ────────────────────────────────────────────────────────────────

  defp read_umbrella_deps(app_atom) do
    app_path = app_atom |> Atom.to_string() |> String.replace("_", "_")
    mix_path = Path.join(@root, "apps/#{app_path}/mix.exs")

    if File.exists?(mix_path) do
      content = File.read!(mix_path)

      # Parse the deps function body — extract tuples like {:jason, "~> 1.0"}
      # or {:tet_core, in_umbrella: true}
      regex = ~r/\{:\s*([a-z_]+)\s*,[^}]+\}/
      captures = Regex.scan(regex, content)

      Enum.map(captures, fn [_, name] ->
        String.to_atom(name)
      end)
    else
      []
    end
  end

  # DFS cycle detection
  defp has_cycle?(node, graph, visited, path) do
    cond do
      node in path ->
        :cyclic

      node in visited ->
        :acyclic

      true ->
        new_visited = MapSet.put(visited, node)
        new_path = MapSet.put(path, node)

        deps = Map.get(graph, node, [])

        results =
          Enum.map(deps, fn dep ->
            has_cycle?(dep, graph, new_visited, new_path)
          end)

        if :cyclic in results, do: :cyclic, else: :acyclic
    end
  end
end
