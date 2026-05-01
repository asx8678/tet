defmodule Tet.Repair.SafeReleaseTest do
  use ExUnit.Case, async: true

  @moduletag :tet_core

  alias Tet.Repair.SafeRelease

  @valid_attrs %{id: "rel_001"}

  describe "new/1" do
    test "builds with minimum attrs and sensible defaults" do
      assert {:ok, release} = SafeRelease.new(@valid_attrs)

      assert release.id == "rel_001"
      assert release.mode == :fallback
      assert release.capabilities == [:diagnose, :patch, :compile, :smoke, :handoff]
      assert release.restricted_tools == [:read, :search, :list, :patch, :compile]
      assert release.excluded_deps == []
      assert release.health_check_interval == 5_000
      assert release.max_repair_attempts == 3
      assert release.handoff_strategy == :graceful
    end

    test "accepts all valid modes" do
      for mode <- [:standalone, :embedded, :fallback] do
        assert {:ok, release} = SafeRelease.new(%{id: "rel_#{mode}", mode: mode})
        assert release.mode == mode
      end
    end

    test "accepts custom capabilities subset" do
      attrs = %{id: "rel_custom", capabilities: [:diagnose, :handoff]}
      assert {:ok, release} = SafeRelease.new(attrs)
      assert release.capabilities == [:diagnose, :handoff]
    end

    test "accepts custom restricted tools subset" do
      attrs = %{id: "rel_tools", restricted_tools: [:read, :list]}
      assert {:ok, release} = SafeRelease.new(attrs)
      assert release.restricted_tools == [:read, :list]
    end

    test "accepts excluded deps" do
      attrs = %{id: "rel_deps", excluded_deps: [:phoenix, :ecto]}
      assert {:ok, release} = SafeRelease.new(attrs)
      assert release.excluded_deps == [:phoenix, :ecto]
    end

    test "accepts custom numeric fields" do
      attrs = %{id: "rel_nums", health_check_interval: 10_000, max_repair_attempts: 5}
      assert {:ok, release} = SafeRelease.new(attrs)
      assert release.health_check_interval == 10_000
      assert release.max_repair_attempts == 5
    end

    test "accepts all handoff strategies" do
      for strategy <- [:graceful, :force, :manual] do
        attrs = %{id: "rel_hs_#{strategy}", handoff_strategy: strategy}
        assert {:ok, release} = SafeRelease.new(attrs)
        assert release.handoff_strategy == strategy
      end
    end

    test "accepts string keyed attrs" do
      attrs = %{"id" => "rel_str", "mode" => "standalone"}
      assert {:ok, release} = SafeRelease.new(attrs)
      assert release.id == "rel_str"
      assert release.mode == :standalone
    end

    test "accepts string handoff strategy" do
      attrs = %{"id" => "rel_hs_str", "handoff_strategy" => "force"}
      assert {:ok, release} = SafeRelease.new(attrs)
      assert release.handoff_strategy == :force
    end

    test "rejects missing id" do
      assert {:error, {:invalid_entity_field, :safe_release, :id}} =
               SafeRelease.new(%{mode: :fallback})
    end

    test "rejects empty id" do
      assert {:error, {:invalid_entity_field, :safe_release, :id}} =
               SafeRelease.new(%{id: ""})
    end

    test "rejects invalid mode" do
      assert {:error, {:invalid_safe_release_field, :mode}} =
               SafeRelease.new(%{id: "rel_bad", mode: :turbo})
    end

    test "rejects invalid capability in list" do
      assert {:error, {:invalid_safe_release_field, :capabilities}} =
               SafeRelease.new(%{id: "rel_bad", capabilities: [:teleport]})
    end

    test "rejects invalid restricted tool" do
      assert {:error, {:invalid_safe_release_field, :restricted_tools}} =
               SafeRelease.new(%{id: "rel_bad", restricted_tools: [:delete]})
    end

    test "rejects non-list excluded deps" do
      assert {:error, {:invalid_safe_release_field, :excluded_deps}} =
               SafeRelease.new(%{id: "rel_bad", excluded_deps: "phoenix"})
    end

    test "rejects non-atom excluded deps entries" do
      assert {:error, {:invalid_safe_release_field, :excluded_deps}} =
               SafeRelease.new(%{id: "rel_bad", excluded_deps: ["phoenix"]})
    end

    test "rejects zero health_check_interval" do
      assert {:error, {:invalid_safe_release_field, :health_check_interval}} =
               SafeRelease.new(%{id: "rel_bad", health_check_interval: 0})
    end

    test "rejects negative health_check_interval" do
      assert {:error, {:invalid_safe_release_field, :health_check_interval}} =
               SafeRelease.new(%{id: "rel_bad", health_check_interval: -1})
    end

    test "rejects zero max_repair_attempts" do
      assert {:error, {:invalid_safe_release_field, :max_repair_attempts}} =
               SafeRelease.new(%{id: "rel_bad", max_repair_attempts: 0})
    end

    test "rejects invalid handoff strategy" do
      assert {:error, {:invalid_safe_release_field, :handoff_strategy}} =
               SafeRelease.new(%{id: "rel_bad", handoff_strategy: :yolo})
    end

    test "rejects non-map input" do
      assert {:error, :invalid_safe_release} = SafeRelease.new("nope")
      assert {:error, :invalid_safe_release} = SafeRelease.new(42)
    end
  end

  describe "validate/1" do
    test "returns :ok for a valid default release" do
      {:ok, release} = SafeRelease.new(@valid_attrs)
      assert :ok = SafeRelease.validate(release)
    end

    test "returns :ok for all valid modes" do
      for mode <- SafeRelease.modes() do
        {:ok, release} = SafeRelease.new(%{id: "rel_v_#{mode}", mode: mode})
        assert :ok = SafeRelease.validate(release)
      end
    end

    test "detects missing required capabilities" do
      {:ok, release} = SafeRelease.new(%{id: "rel_v", capabilities: [:diagnose, :patch]})

      assert {:error, {:missing_required_capabilities, [:handoff]}} =
               SafeRelease.validate(release)
    end

    test "detects mutated invalid mode" do
      {:ok, release} = SafeRelease.new(@valid_attrs)
      bad = %{release | mode: :turbo}
      assert {:error, {:invalid_safe_release_field, :mode}} = SafeRelease.validate(bad)
    end

    test "detects mutated invalid health_check_interval" do
      {:ok, release} = SafeRelease.new(@valid_attrs)
      bad = %{release | health_check_interval: -1}

      assert {:error, {:invalid_safe_release_field, :health_check_interval}} =
               SafeRelease.validate(bad)
    end

    test "detects mutated invalid max_repair_attempts" do
      {:ok, release} = SafeRelease.new(@valid_attrs)
      bad = %{release | max_repair_attempts: 0}

      assert {:error, {:invalid_safe_release_field, :max_repair_attempts}} =
               SafeRelease.validate(bad)
    end

    test "detects mutated invalid handoff_strategy" do
      {:ok, release} = SafeRelease.new(@valid_attrs)
      bad = %{release | handoff_strategy: :yolo}

      assert {:error, {:invalid_safe_release_field, :handoff_strategy}} =
               SafeRelease.validate(bad)
    end
  end

  describe "can_boot?/1" do
    test "returns true for valid default config" do
      {:ok, release} = SafeRelease.new(@valid_attrs)
      assert SafeRelease.can_boot?(release)
    end

    test "returns true for all valid modes" do
      for mode <- SafeRelease.modes() do
        {:ok, release} = SafeRelease.new(%{id: "rel_b_#{mode}", mode: mode})
        assert SafeRelease.can_boot?(release)
      end
    end

    test "returns false without diagnose capability" do
      {:ok, release} = SafeRelease.new(%{id: "rel_nb", capabilities: [:patch, :handoff]})
      refute SafeRelease.can_boot?(release)
    end

    test "returns false with mutated invalid mode" do
      {:ok, release} = SafeRelease.new(@valid_attrs)
      bad = %{release | mode: :turbo}
      refute SafeRelease.can_boot?(bad)
    end

    test "returns false with zero repair attempts" do
      {:ok, release} = SafeRelease.new(@valid_attrs)
      bad = %{release | max_repair_attempts: 0}
      refute SafeRelease.can_boot?(bad)
    end
  end

  describe "capability_available?/2" do
    test "returns true for all default capabilities" do
      {:ok, release} = SafeRelease.new(@valid_attrs)

      for cap <- SafeRelease.valid_capabilities() do
        assert SafeRelease.capability_available?(release, cap)
      end
    end

    test "returns false for capabilities not in the list" do
      {:ok, release} = SafeRelease.new(%{id: "rel_cap", capabilities: [:diagnose, :handoff]})

      refute SafeRelease.capability_available?(release, :patch)
      refute SafeRelease.capability_available?(release, :compile)
      refute SafeRelease.capability_available?(release, :smoke)
    end
  end

  describe "pipeline/1" do
    test "returns full pipeline with all capabilities" do
      {:ok, release} = SafeRelease.new(@valid_attrs)

      assert SafeRelease.pipeline(release) == [
               :diagnose,
               :plan,
               :approve,
               :checkpoint,
               :patch,
               :compile,
               :smoke,
               :handoff
             ]
    end

    test "filters pipeline based on capabilities" do
      {:ok, release} =
        SafeRelease.new(%{id: "rel_p", capabilities: [:diagnose, :compile, :handoff]})

      assert SafeRelease.pipeline(release) == [
               :diagnose,
               :plan,
               :approve,
               :checkpoint,
               :compile,
               :handoff
             ]
    end

    test "always includes infrastructure steps" do
      {:ok, release} = SafeRelease.new(%{id: "rel_inf", capabilities: [:diagnose, :handoff]})
      pipeline = SafeRelease.pipeline(release)

      assert :plan in pipeline
      assert :approve in pipeline
      assert :checkpoint in pipeline
    end

    test "pipeline maintains canonical order" do
      {:ok, release} = SafeRelease.new(@valid_attrs)
      pipeline = SafeRelease.pipeline(release)

      alias Tet.Repair.SafeRelease.Pipeline
      assert :ok = Pipeline.validate_step_order(pipeline)
    end
  end

  describe "handoff_ready?/1" do
    test "returns true with handoff and diagnose capabilities" do
      {:ok, release} = SafeRelease.new(@valid_attrs)
      assert SafeRelease.handoff_ready?(release)
    end

    test "returns true for all valid handoff strategies" do
      for strategy <- SafeRelease.valid_handoff_strategies() do
        {:ok, release} = SafeRelease.new(%{id: "rel_hr_#{strategy}", handoff_strategy: strategy})
        assert SafeRelease.handoff_ready?(release)
      end
    end

    test "returns false without handoff capability" do
      {:ok, release} = SafeRelease.new(%{id: "rel_hr", capabilities: [:diagnose, :patch]})
      refute SafeRelease.handoff_ready?(release)
    end

    test "returns false without diagnose capability" do
      {:ok, release} = SafeRelease.new(%{id: "rel_hr2", capabilities: [:patch, :handoff]})
      refute SafeRelease.handoff_ready?(release)
    end

    test "returns false with mutated invalid handoff_strategy" do
      {:ok, release} = SafeRelease.new(@valid_attrs)
      bad = %{release | handoff_strategy: :yolo}
      refute SafeRelease.handoff_ready?(bad)
    end
  end

  describe "accessor functions" do
    test "modes/0" do
      assert SafeRelease.modes() == [:standalone, :embedded, :fallback]
    end

    test "valid_capabilities/0" do
      assert SafeRelease.valid_capabilities() == [:diagnose, :patch, :compile, :smoke, :handoff]
    end

    test "valid_restricted_tools/0" do
      assert SafeRelease.valid_restricted_tools() == [:read, :search, :list, :patch, :compile]
    end

    test "valid_handoff_strategies/0" do
      assert SafeRelease.valid_handoff_strategies() == [:graceful, :force, :manual]
    end
  end
end
