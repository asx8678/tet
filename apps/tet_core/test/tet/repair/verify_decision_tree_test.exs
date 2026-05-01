defmodule Tet.Repair.VerifyDecisionTreeTest do
  use ExUnit.Case, async: true

  @moduletag :tet_core

  alias Tet.Repair.VerifyDecisionTree

  describe "decide/1" do
    test "returns :manual_intervention when compile fails" do
      patch_result = %{
        compile_status: :fail,
        smoke_status: :pass,
        changed_modules: [MyApp.Helpers.Foo]
      }

      assert {:ok, :manual_intervention} = VerifyDecisionTree.decide(patch_result)
    end

    test "returns :full_restart when smoke test fails" do
      patch_result = %{
        compile_status: :pass,
        smoke_status: :fail,
        changed_modules: [MyApp.Helpers.Foo]
      }

      assert {:ok, :full_restart} = VerifyDecisionTree.decide(patch_result)
    end

    test "returns :hot_reload when all modules are safe" do
      patch_result = %{
        compile_status: :pass,
        smoke_status: :pass,
        changed_modules: [MyApp.Helpers.Foo, MyApp.StringUtils]
      }

      assert {:ok, :hot_reload} = VerifyDecisionTree.decide(patch_result)
    end

    test "returns :full_restart when any module is unsafe" do
      patch_result = %{
        compile_status: :pass,
        smoke_status: :pass,
        changed_modules: [MyApp.Helpers.Foo, MyApp.OrderServer]
      }

      assert {:ok, :full_restart} = VerifyDecisionTree.decide(patch_result)
    end

    test "unsafe modules with release config use release_handler" do
      result = %{
        compile_status: :pass,
        smoke_status: :pass,
        changed_modules: [GenServer],
        has_release_config: true
      }

      assert {:ok, :release_handler} == VerifyDecisionTree.decide(result)
    end

    test "returns :full_restart when modules are unknown" do
      patch_result = %{
        compile_status: :pass,
        smoke_status: :pass,
        changed_modules: [MyApp.SomethingWeird]
      }

      assert {:ok, :full_restart} = VerifyDecisionTree.decide(patch_result)
    end

    test "returns :hot_reload when safe modules + release config (hot_reload takes precedence)" do
      patch_result = %{
        compile_status: :pass,
        smoke_status: :pass,
        changed_modules: [MyApp.Helpers.Foo],
        has_release_config: true
      }

      assert {:ok, :hot_reload} = VerifyDecisionTree.decide(patch_result)
    end

    test "returns :hot_reload when safe modules + no release config" do
      patch_result = %{
        compile_status: :pass,
        smoke_status: :pass,
        changed_modules: [MyApp.Helpers.Foo],
        has_release_config: false
      }

      assert {:ok, :hot_reload} = VerifyDecisionTree.decide(patch_result)
    end

    test "returns :full_restart when no changed modules listed" do
      patch_result = %{
        compile_status: :pass,
        smoke_status: :pass
      }

      assert {:ok, :full_restart} = VerifyDecisionTree.decide(patch_result)
    end

    test "returns :full_restart with empty module list" do
      patch_result = %{
        compile_status: :pass,
        smoke_status: :pass,
        changed_modules: []
      }

      assert {:ok, :full_restart} = VerifyDecisionTree.decide(patch_result)
    end

    test "compile failure short-circuits — ignores safe modules" do
      patch_result = %{
        compile_status: :fail,
        smoke_status: :pass,
        changed_modules: [MyApp.Helpers.Foo]
      }

      assert {:ok, :manual_intervention} = VerifyDecisionTree.decide(patch_result)
    end

    test "skipped compile still allows hot reload if modules safe" do
      patch_result = %{
        compile_status: :skip,
        smoke_status: :pass,
        changed_modules: [MyApp.Helpers.Foo]
      }

      assert {:ok, :hot_reload} = VerifyDecisionTree.decide(patch_result)
    end

    test "skipped smoke still allows hot reload if modules safe" do
      patch_result = %{
        compile_status: :pass,
        smoke_status: :skip,
        changed_modules: [MyApp.Helpers.Foo]
      }

      assert {:ok, :hot_reload} = VerifyDecisionTree.decide(patch_result)
    end

    test "handles minimal input gracefully" do
      assert {:ok, :full_restart} = VerifyDecisionTree.decide(%{})
    end
  end

  describe "compile_check/1" do
    test "returns :pass when compile succeeded" do
      assert VerifyDecisionTree.compile_check(%{compile_status: :pass}) == :pass
    end

    test "returns :fail when compile failed" do
      assert VerifyDecisionTree.compile_check(%{compile_status: :fail}) == :fail
    end

    test "returns :skip when compile was skipped" do
      assert VerifyDecisionTree.compile_check(%{compile_status: :skip}) == :skip
    end

    test "returns :skip when no compile_status present" do
      assert VerifyDecisionTree.compile_check(%{}) == :skip
    end
  end

  describe "smoke_test/1" do
    test "returns :pass when smoke tests passed" do
      assert VerifyDecisionTree.smoke_test(%{smoke_status: :pass}) == :pass
    end

    test "returns :fail when smoke tests failed" do
      assert VerifyDecisionTree.smoke_test(%{smoke_status: :fail}) == :fail
    end

    test "returns :skip when smoke tests were skipped" do
      assert VerifyDecisionTree.smoke_test(%{smoke_status: :skip}) == :skip
    end

    test "returns :skip when no smoke_status present" do
      assert VerifyDecisionTree.smoke_test(%{}) == :skip
    end
  end

  describe "classify_modules/1" do
    test "classifies a list of changed modules" do
      result =
        VerifyDecisionTree.classify_modules(%{
          changed_modules: [MyApp.Helpers.Foo, MyApp.OrderServer]
        })

      assert {MyApp.Helpers.Foo, :safe_reload} in result
      assert {MyApp.OrderServer, :unsafe_reload} in result
    end

    test "returns empty list when no modules" do
      assert VerifyDecisionTree.classify_modules(%{}) == []
    end

    test "handles string module names" do
      result =
        VerifyDecisionTree.classify_modules(%{
          changed_modules: ["MyApp.Helpers.Foo", "MyApp.OrderServer"]
        })

      assert {"MyApp.Helpers.Foo", :safe_reload} in result
      assert {"MyApp.OrderServer", :unsafe_reload} in result
    end
  end

  describe "hot_reload_safe?/1" do
    test "returns true when all modules are safe" do
      assert VerifyDecisionTree.hot_reload_safe?(%{
               changed_modules: [MyApp.Helpers.Foo, MyApp.StringUtils]
             })
    end

    test "returns false when any module is unsafe" do
      refute VerifyDecisionTree.hot_reload_safe?(%{
               changed_modules: [MyApp.Helpers.Foo, MyApp.OrderServer]
             })
    end

    test "returns false when any module is unknown" do
      refute VerifyDecisionTree.hot_reload_safe?(%{
               changed_modules: [MyApp.Helpers.Foo, MyApp.SomethingWeird]
             })
    end

    test "returns false with empty module list" do
      refute VerifyDecisionTree.hot_reload_safe?(%{changed_modules: []})
    end

    test "returns false with no module list" do
      refute VerifyDecisionTree.hot_reload_safe?(%{})
    end
  end
end
