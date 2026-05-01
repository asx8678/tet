defmodule Tet.PlanMode.Evaluator.ProfileTest do
  @moduledoc """
  BD-0032: Evaluator profile construction and validation tests.
  """
  use ExUnit.Case, async: true

  alias Tet.PlanMode.Evaluator.Profile

  # -- Construction --

  describe "profile construction" do
    test "default profile has moderate aggressiveness, medium risk, no focus" do
      profile = Profile.default()
      assert profile.aggressiveness == :moderate
      assert profile.risk_tolerance == :medium
      assert profile.focus_areas == []
    end

    test "conservative profile has conservative aggressiveness and low risk" do
      profile = Profile.conservative()
      assert profile.aggressiveness == :conservative
      assert profile.risk_tolerance == :low
      assert profile.focus_areas == []
    end

    test "aggressive profile has aggressive guidance and high risk" do
      profile = Profile.aggressive()
      assert profile.aggressiveness == :aggressive
      assert profile.risk_tolerance == :high
      assert profile.focus_areas == []
    end

    test "new/1 with valid attributes builds profile" do
      assert {:ok, profile} =
               Profile.new(%{
                 aggressiveness: :conservative,
                 risk_tolerance: :high,
                 focus_areas: [:file_safety]
               })

      assert profile.aggressiveness == :conservative
      assert profile.risk_tolerance == :high
      assert profile.focus_areas == [:file_safety]
    end

    test "new/1 with partial attributes uses defaults" do
      assert {:ok, profile} = Profile.new(%{aggressiveness: :aggressive})
      assert profile.aggressiveness == :aggressive
      assert profile.risk_tolerance == :medium
      assert profile.focus_areas == []
    end

    test "new/1 with empty map returns default profile" do
      assert {:ok, profile} = Profile.new(%{})
      assert profile == Profile.default()
    end

    test "new!/1 raises on invalid attributes" do
      assert_raise ArgumentError, ~r/invalid evaluator profile/, fn ->
        Profile.new!(%{aggressiveness: :invalid})
      end
    end
  end

  # -- Validation --

  describe "profile validation" do
    test "rejects invalid aggressiveness" do
      assert {:error, {:invalid_profile_field, {:aggressiveness, :invalid}}} =
               Profile.new(%{aggressiveness: :invalid})
    end

    test "rejects invalid risk tolerance" do
      assert {:error, {:invalid_profile_field, {:risk_tolerance, :extreme}}} =
               Profile.new(%{risk_tolerance: :extreme})
    end

    test "rejects non-list focus areas" do
      assert {:error, {:invalid_profile_field, {:focus_areas, :not_a_list}}} =
               Profile.new(%{focus_areas: :not_a_list})
    end

    test "rejects focus areas with non-atom elements" do
      assert {:error, {:invalid_profile_field, {:focus_areas, :not_all_atoms}}} =
               Profile.new(%{focus_areas: [:valid, "invalid"]})
    end

    test "accepts all valid aggressiveness levels" do
      for level <- Profile.aggressiveness_levels() do
        assert {:ok, _} = Profile.new(%{aggressiveness: level})
      end
    end

    test "accepts all valid risk levels" do
      for level <- Profile.risk_levels() do
        assert {:ok, _} = Profile.new(%{risk_tolerance: level})
      end
    end

    test "accepts custom focus area atoms" do
      assert {:ok, profile} = Profile.new(%{focus_areas: [:custom_area, :another]})
      assert profile.focus_areas == [:custom_area, :another]
    end
  end

  # -- Helpers --

  describe "profile helpers" do
    test "has_focus? returns false for empty focus areas" do
      refute Profile.has_focus?(Profile.default())
    end

    test "has_focus? returns true when focus areas are set" do
      profile = Profile.new!(%{focus_areas: [:file_safety]})
      assert Profile.has_focus?(profile)
    end

    test "aggressiveness_at_least? works correctly" do
      conservative = Profile.new!(%{aggressiveness: :conservative})
      moderate = Profile.new!(%{aggressiveness: :moderate})
      aggressive = Profile.new!(%{aggressiveness: :aggressive})

      # Conservative
      assert Profile.aggressiveness_at_least?(conservative, :conservative)
      refute Profile.aggressiveness_at_least?(conservative, :moderate)
      refute Profile.aggressiveness_at_least?(conservative, :aggressive)

      # Moderate
      assert Profile.aggressiveness_at_least?(moderate, :conservative)
      assert Profile.aggressiveness_at_least?(moderate, :moderate)
      refute Profile.aggressiveness_at_least?(moderate, :aggressive)

      # Aggressive
      assert Profile.aggressiveness_at_least?(aggressive, :conservative)
      assert Profile.aggressiveness_at_least?(aggressive, :moderate)
      assert Profile.aggressiveness_at_least?(aggressive, :aggressive)
    end

    test "risk_at_least? works correctly" do
      low = Profile.new!(%{risk_tolerance: :low})
      medium = Profile.new!(%{risk_tolerance: :medium})
      high = Profile.new!(%{risk_tolerance: :high})

      assert Profile.risk_at_least?(low, :low)
      refute Profile.risk_at_least?(low, :medium)
      refute Profile.risk_at_least?(low, :high)

      assert Profile.risk_at_least?(medium, :low)
      assert Profile.risk_at_least?(medium, :medium)
      refute Profile.risk_at_least?(medium, :high)

      assert Profile.risk_at_least?(high, :low)
      assert Profile.risk_at_least?(high, :medium)
      assert Profile.risk_at_least?(high, :high)
    end

    test "known_focus_areas returns list of atoms" do
      areas = Profile.known_focus_areas()
      assert is_list(areas)
      assert Enum.all?(areas, &is_atom/1)
    end
  end
end
