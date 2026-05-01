defmodule Tet.Release.DependencyClosureTest do
  use ExUnit.Case, async: true

  alias Tet.Release
  alias Tet.Release.DependencyClosure

  describe "compute/1" do
    test "returns just the app itself for a leaf node with no deps" do
      # tet_core has no umbrella-internal deps
      result = DependencyClosure.compute([:tet_core])
      assert :tet_core in result
      assert length(result) == 1
    end

    test "computes transitive closure for a single app" do
      result = DependencyClosure.compute([:tet_cli])

      assert :tet_cli in result
      assert :tet_runtime in result
      assert :tet_core in result
    end

    test "computes closure for tet_runtime" do
      result = DependencyClosure.compute([:tet_runtime])

      assert :tet_runtime in result
      assert :tet_core in result
      assert length(result) == 2
    end

    test "computes closure for tet_web_phoenix" do
      result = DependencyClosure.compute([:tet_web_phoenix])

      assert :tet_web_phoenix in result
      assert :tet_runtime in result
      assert :tet_core in result
    end

    test "computes closure for multiple apps without duplicates" do
      result = DependencyClosure.compute([:tet_cli, :tet_store_sqlite])

      assert :tet_cli in result
      assert :tet_store_sqlite in result
      assert :tet_runtime in result
      assert :tet_core in result

      # No duplicates
      assert length(result) == length(Enum.uniq(result))
    end

    test "empty input returns empty closure" do
      assert DependencyClosure.compute([]) == []
    end

    test "standalone apps closure does not include web apps" do
      result = DependencyClosure.compute(Release.standalone_apps())

      for web_app <- Release.web_apps() do
        assert web_app not in result,
               "web app #{inspect(web_app)} leaked into standalone closure"
      end
    end
  end

  describe "overlap/2" do
    test "finds shared deps between two closures" do
      closure_a = [:tet_core, :tet_runtime, :tet_cli]
      closure_b = [:tet_core, :tet_runtime, :tet_web_phoenix]

      assert DependencyClosure.overlap(closure_a, closure_b) == [:tet_core, :tet_runtime]
    end

    test "returns empty list for disjoint closures" do
      closure_a = [:tet_core]
      closure_b = [:tet_web_phoenix]

      assert DependencyClosure.overlap(closure_a, closure_b) == []
    end

    test "handles identical closures" do
      closure = [:tet_core, :tet_runtime]

      assert DependencyClosure.overlap(closure, closure) == Enum.sort(closure)
    end
  end

  describe "exclusive/2" do
    test "finds deps exclusive to first closure" do
      closure_a = [:tet_core, :tet_runtime, :tet_cli]
      closure_b = [:tet_core, :tet_runtime, :tet_web_phoenix]

      assert DependencyClosure.exclusive(closure_a, closure_b) == [:tet_cli]
    end

    test "finds deps exclusive to web but not standalone" do
      standalone_closure = DependencyClosure.compute(Release.standalone_apps())
      web_closure = DependencyClosure.compute(Release.web_apps())

      web_only = DependencyClosure.exclusive(web_closure, standalone_closure)

      assert :tet_web_phoenix in web_only
    end

    test "returns full list when closures are disjoint" do
      closure_a = [:tet_core, :tet_cli]
      closure_b = [:tet_web_phoenix]

      assert DependencyClosure.exclusive(closure_a, closure_b) == [:tet_cli, :tet_core]
    end

    test "returns empty list when first closure is subset of second" do
      closure_a = [:tet_core]
      closure_b = [:tet_core, :tet_runtime]

      assert DependencyClosure.exclusive(closure_a, closure_b) == []
    end
  end

  describe "verify_no_web_in_standalone/0" do
    test "passes when standalone has no web deps" do
      assert :ok == DependencyClosure.verify_no_web_in_standalone()
    end
  end
end
