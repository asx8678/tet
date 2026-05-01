defmodule Tet.Repair.VerifyDecisionTree.ModuleClassifierTest do
  use ExUnit.Case, async: true

  @moduletag :tet_core

  alias Tet.Repair.VerifyDecisionTree.ModuleClassifier

  describe "classify/1 with atom modules" do
    test "classifies helper modules as safe" do
      assert ModuleClassifier.classify(MyApp.Helpers.StringUtils) == :safe_reload
      assert ModuleClassifier.classify(MyApp.FormatHelper) == :safe_reload
      assert ModuleClassifier.classify(MyApp.DateHelpers) == :safe_reload
    end

    test "classifies util modules as safe" do
      assert ModuleClassifier.classify(MyApp.Utils.FileUtil) == :safe_reload
      assert ModuleClassifier.classify(MyApp.PathUtils) == :safe_reload
    end

    test "classifies struct/schema modules as safe" do
      assert ModuleClassifier.classify(MyApp.UserSchema) == :safe_reload
      assert ModuleClassifier.classify(MyApp.OrderStruct) == :safe_reload
    end

    test "classifies view/formatter/parser/validator modules as safe" do
      assert ModuleClassifier.classify(MyApp.UserView) == :safe_reload
      assert ModuleClassifier.classify(MyApp.DateFormatter) == :safe_reload
      assert ModuleClassifier.classify(MyApp.JsonParser) == :safe_reload
      assert ModuleClassifier.classify(MyApp.InputValidator) == :safe_reload
    end

    test "classifies GenServer modules as unsafe" do
      assert ModuleClassifier.classify(MyApp.OrderServer) == :unsafe_reload
      assert ModuleClassifier.classify(MyApp.CacheGenServer) == :unsafe_reload
    end

    test "classifies Supervisor modules as unsafe" do
      assert ModuleClassifier.classify(MyApp.WorkerSupervisor) == :unsafe_reload
      assert ModuleClassifier.classify(MyApp.AppSupervisor) == :unsafe_reload
    end

    test "classifies Application modules as unsafe" do
      assert ModuleClassifier.classify(MyApp.Application) == :unsafe_reload
    end

    test "classifies Worker modules as unsafe" do
      assert ModuleClassifier.classify(MyApp.EmailWorker) == :unsafe_reload
    end

    test "classifies Migration modules as unsafe" do
      assert ModuleClassifier.classify(MyApp.Repo.Migration) == :unsafe_reload
      assert ModuleClassifier.classify(MyApp.AddUsersMigration) == :unsafe_reload
    end

    test "classifies Registry modules as unsafe" do
      assert ModuleClassifier.classify(MyApp.ProcessRegistry) == :unsafe_reload
    end

    test "classifies Agent modules as unsafe" do
      assert ModuleClassifier.classify(MyApp.StateAgent) == :unsafe_reload
    end

    test "classifies unknown modules as unknown" do
      assert ModuleClassifier.classify(MyApp.SomethingWeird) == :unknown
      assert ModuleClassifier.classify(MyApp.Core.Logic) == :unknown
    end

    test "unsafe takes precedence when both patterns match" do
      # A module with both "Helper" and "Server" in path — unsafe wins
      assert ModuleClassifier.classify(MyApp.Server.HelperUtils) == :unsafe_reload
    end
  end

  describe "classify/1 with string module names" do
    test "classifies string module names" do
      assert ModuleClassifier.classify("MyApp.Helpers.Foo") == :safe_reload
      assert ModuleClassifier.classify("MyApp.OrderServer") == :unsafe_reload
      assert ModuleClassifier.classify("MyApp.Something") == :unknown
    end
  end

  describe "classify/1 with file paths" do
    test "classifies file paths by converting to module names" do
      assert ModuleClassifier.classify("lib/my_app/helpers/string_utils.ex") == :safe_reload
      assert ModuleClassifier.classify("lib/my_app/order_server.ex") == :unsafe_reload
    end

    test "handles nested paths" do
      assert ModuleClassifier.classify("apps/core/lib/core/utils/date_formatter.ex") ==
               :safe_reload
    end
  end

  describe "classify/1 with loaded modules and behaviours" do
    # Define a GenServer with a safe-sounding name to test behaviour override
    defmodule Helpers.CacheUtil do
      use GenServer, restart: :temporary

      def start_link(_) do
        GenServer.start_link(__MODULE__, nil)
      end

      @impl true
      def init(_), do: {:ok, %{}}
    end

    test "classifies GenServer behaviour modules as unsafe" do
      # GenServer is a loaded module with known behaviours
      assert ModuleClassifier.classify(GenServer) == :unsafe_reload
    end

    test "GenServer named Helpers is classified as unsafe" do
      # A GenServer with a safe-sounding name must still be unsafe
      assert ModuleClassifier.classify(Helpers.CacheUtil) == :unsafe_reload
    end

    test "classifies struct modules as safe when name is unknown" do
      # MapSet is a loaded module that defines __struct__/0
      # but its name doesn't match safe/unsafe patterns
      # Behaviour detection will find the struct → safe
      assert ModuleClassifier.classify(MapSet) == :safe_reload
    end
  end

  describe "safe_patterns/0" do
    test "returns suffixes and infixes" do
      patterns = ModuleClassifier.safe_patterns()
      assert is_list(patterns.suffixes)
      assert is_list(patterns.infixes)
      assert "Helper" in patterns.suffixes
      assert "Utils" in patterns.suffixes
      assert "Helpers" in patterns.infixes
    end
  end

  describe "unsafe_patterns/0" do
    test "returns suffixes and infixes" do
      patterns = ModuleClassifier.unsafe_patterns()
      assert is_list(patterns.suffixes)
      assert is_list(patterns.infixes)
      assert "Server" in patterns.suffixes
      assert "Supervisor" in patterns.suffixes
      assert "Application" in patterns.infixes
    end
  end
end
