defmodule Tet.ReleaseTest do
  use ExUnit.Case, async: true

  alias Tet.Release

  describe "standalone/0" do
    test "returns a valid standalone release config" do
      config = Release.standalone()

      assert %Release{} = config
      assert config.name == :tet_standalone
      assert config.mode == :standalone
      assert :tet_core in config.apps
      assert :tet_runtime in config.apps
      assert :tet_cli in config.apps
      assert :tet_store_sqlite in config.apps
      assert :tet_web_phoenix not in config.apps
      assert :tet_store_memory not in config.apps
    end

    test "standalone apps do not include web or optional apps" do
      config = Release.standalone()

      for web_app <- Release.web_apps() do
        assert web_app not in config.apps,
               "web app #{inspect(web_app)} leaked into standalone"
      end

      for opt_app <- Release.optional_apps() do
        assert opt_app not in config.apps,
               "optional app #{inspect(opt_app)} leaked into standalone"
      end
    end
  end

  describe "web/0" do
    test "returns a valid web release config" do
      config = Release.web()

      assert %Release{} = config
      assert config.name == :tet_web
      assert config.mode == :web
      assert :tet_web_phoenix in config.apps
      assert :tet_store_memory not in config.apps
    end

    test "web config includes all standalone apps plus web apps" do
      config = Release.web()

      for app <- Release.standalone_apps() do
        assert app in config.apps, "standalone app #{inspect(app)} missing from web config"
      end

      for app <- Release.web_apps() do
        assert app in config.apps, "web app #{inspect(app)} missing from web config"
      end
    end
  end

  describe "full/0" do
    test "returns a valid full release config" do
      config = Release.full()

      assert %Release{} = config
      assert config.name == :tet_full
      assert config.mode == :full
      assert :tet_web_phoenix in config.apps
      assert :tet_store_memory in config.apps
    end

    test "full config includes all apps" do
      config = Release.full()

      all_apps = Release.standalone_apps() ++ Release.web_apps() ++ Release.optional_apps()

      for app <- all_apps do
        assert app in config.apps, "app #{inspect(app)} missing from full config"
      end
    end
  end

  describe "apps_for/1" do
    test "standalone mode returns only standalone apps" do
      assert Release.apps_for(:standalone) == Release.standalone_apps()
    end

    test "web mode returns standalone plus web apps" do
      expected = Release.standalone_apps() ++ Release.web_apps()
      assert Release.apps_for(:web) == expected
    end

    test "full mode returns all apps" do
      expected = Release.standalone_apps() ++ Release.web_apps() ++ Release.optional_apps()
      assert Release.apps_for(:full) == expected
    end
  end

  describe "deps_for/1" do
    test "returns transitive closure for a mode" do
      deps = Release.deps_for(:standalone)

      # All standalone apps should appear in their own closure
      for app <- Release.standalone_apps() do
        assert app in deps, "#{inspect(app)} missing from standalone closure"
      end

      # No web apps should appear
      for app <- Release.web_apps() do
        assert app not in deps, "web app #{inspect(app)} leaked into standalone deps"
      end
    end
  end

  describe "validate/1" do
    test "valid standalone config passes validation" do
      assert :ok == Release.validate(Release.standalone())
    end

    test "valid web config passes validation" do
      assert :ok == Release.validate(Release.web())
    end

    test "valid full config passes validation" do
      assert :ok == Release.validate(Release.full())
    end

    test "rejects nil name" do
      config = %Release{Release.standalone() | name: nil}
      assert {:error, _} = Release.validate(config)
    end

    test "rejects invalid mode" do
      config = %Release{Release.standalone() | mode: :bogus}
      assert {:error, _} = Release.validate(config)
    end

    test "rejects empty apps list" do
      config = %Release{Release.standalone() | apps: []}
      assert {:error, _} = Release.validate(config)
    end

    test "rejects web apps in standalone mode" do
      config = %Release{
        Release.standalone()
        | apps: [:tet_web_phoenix | Release.standalone_apps()]
      }

      assert {:error, errors} = Release.validate(config)
      assert Enum.any?(errors, &String.contains?(&1, "forbidden"))
    end
  end

  describe "verify_independence/0" do
    test "standalone does not transitively depend on web apps" do
      assert :ok == Release.verify_independence()
    end
  end

  describe "config agreement with mix.exs" do
    @root Path.expand("../../../..", __DIR__)

    test "Tet.Release.standalone_apps/0 agrees with mix.exs @standalone_applications" do
      mix_content = File.read!(Path.join(@root, "mix.exs"))

      # Extract the app atoms from @standalone_applications in mix.exs
      # Pattern: tet_core: :permanent, tet_store_sqlite: :permanent, ...
      regex = ~r/@standalone_applications\s*\[([^\]]+)\]/
      captures = Regex.run(regex, mix_content)

      assert captures != nil, "Could not find @standalone_applications in mix.exs"

      mix_apps =
        captures
        |> List.last()
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.map(fn entry ->
          [app_name | _] = String.split(entry, ":")
          String.trim(app_name) |> String.to_atom()
        end)
        |> Enum.sort()

      release_apps = Release.standalone_apps() |> Enum.sort()

      assert mix_apps == release_apps,
             "mix.exs @standalone_applications #{inspect(mix_apps)} does not match " <>
               "Tet.Release.standalone_apps/0 #{inspect(release_apps)}"
    end

    test "Tet.Release forbidden lists agree with mix.exs forbidden lists" do
      mix_content = File.read!(Path.join(@root, "mix.exs"))

      # Extract @forbidden_standalone_exact
      exact_regex = ~r/@forbidden_standalone_exact\s*\[([^\]]+)\]/s
      exact_captures = Regex.run(exact_regex, mix_content)

      assert exact_captures != nil,
             "Could not find @forbidden_standalone_exact in mix.exs"

      mix_exact =
        exact_captures
        |> List.last()
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(fn entry ->
          entry |> String.trim_leading(":") |> String.to_atom()
        end)
        |> Enum.sort()

      release_exact = Release.forbidden_standalone_exact() |> Enum.sort()

      assert mix_exact == release_exact,
             "mix.exs @forbidden_standalone_exact #{inspect(mix_exact)} does not match " <>
               "Tet.Release.forbidden_standalone_exact/0 #{inspect(release_exact)}"
    end

    test "Tet.Release forbidden prefixes agree with mix.exs forbidden prefixes" do
      mix_content = File.read!(Path.join(@root, "mix.exs"))

      # Extract @forbidden_standalone_prefixes
      prefix_regex = ~r/@forbidden_standalone_prefixes\s*\[([^\]]+)\]/s
      prefix_captures = Regex.run(prefix_regex, mix_content)

      assert prefix_captures != nil,
             "Could not find @forbidden_standalone_prefixes in mix.exs"

      mix_prefixes =
        prefix_captures
        |> List.last()
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(fn entry ->
          entry |> String.trim(~s{"}) |> String.trim(~s{'})
        end)
        |> Enum.sort()

      release_prefixes = Release.forbidden_standalone_prefixes() |> Enum.sort()

      assert mix_prefixes == release_prefixes,
             "mix.exs @forbidden_standalone_prefixes #{inspect(mix_prefixes)} does not match " <>
               "Tet.Release.forbidden_standalone_prefixes/0 #{inspect(release_prefixes)}"
    end
  end
end
