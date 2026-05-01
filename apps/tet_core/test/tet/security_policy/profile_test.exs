defmodule Tet.SecurityPolicy.ProfileTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Tet.SecurityPolicy.Profile

  describe "new/1" do
    test "creates profile with defaults" do
      {:ok, profile} = Profile.new(%{})

      assert profile.approval_mode == :require_approve
      assert profile.sandbox_profile == :workspace_only
      assert profile.deny_globs == []
      assert profile.allow_paths == nil
      assert profile.mcp_trust == :read
      assert profile.remote_trust == :untrusted_remote
    end

    test "creates profile with custom approval mode" do
      {:ok, profile} = Profile.new(%{approval_mode: :auto_approve})
      assert profile.approval_mode == :auto_approve
    end

    test "creates profile with custom sandbox profile" do
      {:ok, profile} = Profile.new(%{sandbox_profile: :locked_down})
      assert profile.sandbox_profile == :locked_down
    end

    test "creates profile with deny globs and allow paths" do
      {:ok, profile} =
        Profile.new(%{
          deny_globs: ["/etc/**", "/secret/**"],
          allow_paths: ["/workspace/**"]
        })

      assert profile.deny_globs == ["/etc/**", "/secret/**"]
      assert profile.allow_paths == ["/workspace/**"]
    end

    test "creates profile with mcp and remote trust" do
      {:ok, profile} = Profile.new(%{mcp_trust: :write, remote_trust: :local})
      assert profile.mcp_trust == :write
      assert profile.remote_trust == :local
    end

    test "creates profile with custom repair approval" do
      {:ok, profile} =
        Profile.new(%{
          repair_approval: %{
            retry: :auto_approve,
            fallback: :require_approve,
            patch: :always_deny,
            human: :always_deny
          }
        })

      assert profile.repair_approval.retry == :auto_approve
      assert profile.repair_approval.fallback == :require_approve
    end

    test "creates profile with metadata" do
      {:ok, profile} = Profile.new(%{metadata: %{source: "config.yaml"}})
      assert profile.metadata.source == "config.yaml"
    end

    test "rejects invalid approval mode" do
      assert {:error, {:invalid_approval_mode, :wild_west}} =
               Profile.new(%{approval_mode: :wild_west})
    end

    test "rejects invalid sandbox profile" do
      assert {:error, {:invalid_sandbox_profile, :semi_open}} =
               Profile.new(%{sandbox_profile: :semi_open})
    end

    test "rejects non-string in deny_globs" do
      assert {:error, {:invalid_glob_list, :deny_globs}} = Profile.new(%{deny_globs: [123]})
    end

    test "rejects non-list deny_globs" do
      assert {:error, {:invalid_glob_list, :deny_globs}} = Profile.new(%{deny_globs: "bad"})
    end

    test "rejects invalid mcp_trust" do
      assert {:error, {:invalid_mcp_trust, :nuclear}} = Profile.new(%{mcp_trust: :nuclear})
    end

    test "rejects invalid remote_trust" do
      assert {:error, {:invalid_remote_trust, :sketchy}} = Profile.new(%{remote_trust: :sketchy})
    end

    test "rejects invalid repair_approval key" do
      assert {:error, {:invalid_repair_approval, [:extraterrestrial]}} =
               Profile.new(%{repair_approval: %{extraterrestrial: :auto_approve}})
    end

    test "rejects invalid repair_approval value" do
      assert {:error, {:invalid_repair_approval, _}} =
               Profile.new(%{repair_approval: %{retry: :yolo}})
    end

    test "rejects non-map input" do
      assert {:error, :invalid_profile} = Profile.new("bad")
    end

    test "rejects invalid metadata" do
      assert {:error, :invalid_metadata} = Profile.new(%{metadata: "string"})
    end
  end

  describe "new!/1" do
    test "returns profile on success" do
      profile = Profile.new!(%{})
      assert profile.approval_mode == :require_approve
    end

    test "raises on invalid input" do
      assert_raise ArgumentError, ~r/invalid security profile/, fn ->
        Profile.new!(%{approval_mode: :bogus})
      end
    end
  end

  describe "built-in profiles" do
    test "default returns conservative profile" do
      profile = Profile.default()
      assert profile.approval_mode == :require_approve
      assert profile.sandbox_profile == :workspace_only
      assert profile.mcp_trust == :read
      assert profile.remote_trust == :untrusted_remote
    end

    test "permissive returns fully open profile" do
      profile = Profile.permissive()
      assert profile.approval_mode == :auto_approve
      assert profile.sandbox_profile == :unrestricted
      assert profile.mcp_trust == :admin
      assert profile.remote_trust == :local
      assert profile.allow_paths == ["**"]
    end

    test "locked_down returns fully restrictive profile" do
      profile = Profile.locked_down()
      assert profile.approval_mode == :always_deny
      assert profile.sandbox_profile == :locked_down
      assert profile.deny_globs == ["**"]
    end
  end

  describe "approval_ranking/1" do
    test "auto_approve is most permissive" do
      assert Profile.approval_ranking(:auto_approve) == 3
      assert Profile.approval_ranking(:suggest_approve) == 2
      assert Profile.approval_ranking(:require_approve) == 1
      assert Profile.approval_ranking(:always_deny) == 0
    end
  end

  describe "approval_at_least?/2" do
    test "auto_approve meets all levels" do
      assert Profile.approval_at_least?(:auto_approve, :auto_approve)
      assert Profile.approval_at_least?(:auto_approve, :suggest_approve)
      assert Profile.approval_at_least?(:auto_approve, :require_approve)
      assert Profile.approval_at_least?(:auto_approve, :always_deny)
    end

    test "require_approve does not meet suggest_approve" do
      refute Profile.approval_at_least?(:require_approve, :suggest_approve)
    end

    test "require_approve meets require_approve" do
      assert Profile.approval_at_least?(:require_approve, :require_approve)
    end
  end

  describe "sandbox_ranking/1" do
    test "unrestricted is least restrictive" do
      assert Profile.sandbox_ranking(:unrestricted) == 0
      assert Profile.sandbox_ranking(:workspace_only) == 1
      assert Profile.sandbox_ranking(:read_only) == 2
      assert Profile.sandbox_ranking(:no_network) == 3
      assert Profile.sandbox_ranking(:locked_down) == 4
    end

    test "unknown returns nil" do
      assert Profile.sandbox_ranking(:bogus) == nil
    end
  end

  describe "sandbox_at_least?/2" do
    test "locked_down is at least as restrictive as everything" do
      assert Profile.sandbox_at_least?(:locked_down, :unrestricted)
      assert Profile.sandbox_at_least?(:locked_down, :locked_down)
    end

    test "unrestricted is only at least unrestricted" do
      assert Profile.sandbox_at_least?(:unrestricted, :unrestricted)
      refute Profile.sandbox_at_least?(:unrestricted, :workspace_only)
    end

    test "read_only and no_network are incomparable" do
      refute Profile.sandbox_at_least?(:read_only, :no_network)
      refute Profile.sandbox_at_least?(:no_network, :read_only)
    end

    test "read_only is at least workspace_only" do
      assert Profile.sandbox_at_least?(:read_only, :workspace_only)
      assert Profile.sandbox_at_least?(:no_network, :workspace_only)
    end

    test "locked_down is the only profile that meets locked_down" do
      assert Profile.sandbox_at_least?(:locked_down, :locked_down)
      refute Profile.sandbox_at_least?(:read_only, :locked_down)
      refute Profile.sandbox_at_least?(:no_network, :locked_down)
    end
  end

  describe "to_map/1" do
    test "returns JSON-friendly map" do
      profile = Profile.new!(%{approval_mode: :auto_approve})
      map = Profile.to_map(profile)

      assert map.approval_mode == :auto_approve
      assert is_list(map.deny_globs)
      assert is_list(map.allow_paths) or is_nil(map.allow_paths)
      assert is_map(map.repair_approval)
      assert is_map(map.metadata)
    end
  end

  describe "merge/2" do
    test "restrictive merge: picks more restrictive approval_mode" do
      base = Profile.new!(%{approval_mode: :require_approve, sandbox_profile: :workspace_only})
      override = Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :read_only})

      merged = Profile.merge(base, override)
      assert merged.approval_mode == :require_approve
      assert merged.sandbox_profile == :read_only
    end

    test "deny_globs are unioned" do
      base = Profile.new!(%{deny_globs: ["/a/**"]})
      override = Profile.new!(%{deny_globs: ["/b/**"]})
      merged = Profile.merge(base, override)

      assert "/a/**" in merged.deny_globs
      assert "/b/**" in merged.deny_globs
    end

    test "deny_globs union is deduplicated" do
      base = Profile.new!(%{deny_globs: ["/a/**"]})
      override = Profile.new!(%{deny_globs: ["/a/**", "/b/**"]})
      merged = Profile.merge(base, override)

      assert Enum.count(merged.deny_globs, &(&1 == "/a/**")) == 1
    end

    test "allow_paths use intersection when both non-empty" do
      base = Profile.new!(%{allow_paths: ["/workspace/**", "/tmp/**"]})
      override = Profile.new!(%{allow_paths: ["/workspace/**", "/var/**"]})
      merged = Profile.merge(base, override)

      # Only paths present in BOTH survive
      assert merged.allow_paths == ["/workspace/**"]
    end

    test "allow_paths empty when one side is empty" do
      base = Profile.new!(%{allow_paths: ["/old/**"]})
      override = Profile.new!(%{allow_paths: []})
      merged = Profile.merge(base, override)

      # Intersection with empty set is empty — more restrictive
      assert merged.allow_paths == []
    end

    test "allow_paths empty when both are empty" do
      base = Profile.new!(%{allow_paths: []})
      override = Profile.new!(%{allow_paths: []})
      merged = Profile.merge(base, override)

      assert merged.allow_paths == []
    end

    test "repair_approval merges with more restrictive per-key (missing = always_deny)" do
      base = Profile.new!(%{repair_approval: %{retry: :auto_approve, fallback: :suggest_approve}})

      override =
        Profile.new!(%{repair_approval: %{fallback: :always_deny, patch: :require_approve}})

      merged = Profile.merge(base, override)

      # retry: base=auto_approve, override missing → always_deny → more restrictive = always_deny
      assert merged.repair_approval.retry == :always_deny
      # fallback: always_deny is more restrictive than suggest_approve
      assert merged.repair_approval.fallback == :always_deny

      # patch: base missing → always_deny, override=require_approve → more restrictive = always_deny
      assert merged.repair_approval.patch == :always_deny
      # human: both missing → always_deny
      assert merged.repair_approval.human == :always_deny
    end

    test "repair_approval picks more restrictive when base is stricter" do
      base = Profile.new!(%{repair_approval: %{retry: :require_approve}})
      override = Profile.new!(%{repair_approval: %{retry: :auto_approve}})
      merged = Profile.merge(base, override)

      # base require_approve is more restrictive than override auto_approve
      assert merged.repair_approval.retry == :require_approve
    end

    test "metadata deep merges with override winning" do
      base = Profile.new!(%{metadata: %{a: 1, b: 2}})
      override = Profile.new!(%{metadata: %{b: 3, c: 4}})
      merged = Profile.merge(base, override)

      assert merged.metadata == %{a: 1, b: 3, c: 4}
    end

    test "restrictive merge: mcp_trust picks lower trust" do
      base = Profile.new!(%{mcp_trust: :read, remote_trust: :untrusted_remote})
      override = Profile.new!(%{mcp_trust: :write, remote_trust: :local})
      merged = Profile.merge(base, override)

      # mcp_trust: :read is more restrictive (fewer categories)
      assert merged.mcp_trust == :read
      # remote_trust: :local is more restrictive (requires more trust)
      assert merged.remote_trust == :local
    end
  end

  describe "default_repair_approval/0" do
    test "maps all four strategies" do
      approval = Profile.default_repair_approval()

      assert Map.has_key?(approval, :retry)
      assert Map.has_key?(approval, :fallback)
      assert Map.has_key?(approval, :patch)
      assert Map.has_key?(approval, :human)
    end

    test "human is always_deny" do
      assert Profile.default_repair_approval().human == :always_deny
    end

    test "retry is auto_approve" do
      assert Profile.default_repair_approval().retry == :auto_approve
    end
  end

  # --- SECURITY: Restrictive merge ---

  describe "merge/2 security: restrictive choices" do
    test "approval_mode picks more restrictive (lower ranking)" do
      # require_approve (1) vs auto_approve (3) → require_approve
      base = Profile.new!(%{approval_mode: :require_approve})
      override = Profile.new!(%{approval_mode: :auto_approve})
      merged = Profile.merge(base, override)

      assert merged.approval_mode == :require_approve
    end

    test "sandbox_profile picks more restrictive (higher ranking)" do
      # workspace_only (1) vs read_only (2) → read_only
      base = Profile.new!(%{sandbox_profile: :workspace_only})
      override = Profile.new!(%{sandbox_profile: :read_only})
      merged = Profile.merge(base, override)

      assert merged.sandbox_profile == :read_only
    end

    test "sandbox_profile picks locked_down over unrestricted" do
      base = Profile.new!(%{sandbox_profile: :unrestricted})
      override = Profile.new!(%{sandbox_profile: :locked_down})
      merged = Profile.merge(base, override)

      assert merged.sandbox_profile == :locked_down
    end

    test "mcp_trust picks lower trust (fewer categories allowed)" do
      # :read (risk_index 1) vs :write (risk_index 2) → :read
      base = Profile.new!(%{mcp_trust: :read})
      override = Profile.new!(%{mcp_trust: :write})
      merged = Profile.merge(base, override)

      assert merged.mcp_trust == :read
    end

    test "remote_trust picks higher trust requirement (more restrictive)" do
      # :local (ranking 3, requires local) vs :untrusted_remote (ranking 1) → :local
      base = Profile.new!(%{remote_trust: :local})
      override = Profile.new!(%{remote_trust: :untrusted_remote})
      merged = Profile.merge(base, override)

      assert merged.remote_trust == :local
    end

    test "same values merge to same value" do
      base = Profile.new!(%{approval_mode: :require_approve, sandbox_profile: :read_only})
      override = Profile.new!(%{approval_mode: :require_approve, sandbox_profile: :read_only})
      merged = Profile.merge(base, override)

      assert merged.approval_mode == :require_approve
      assert merged.sandbox_profile == :read_only
    end

    test "incomparable sandbox profiles fall to locked_down" do
      # read_only and no_network are incomparable — neither is a subset of the other
      base = Profile.new!(%{sandbox_profile: :read_only})
      override = Profile.new!(%{sandbox_profile: :no_network})
      merged = Profile.merge(base, override)

      assert merged.sandbox_profile == :locked_down
    end

    test "workspace_only + read_only merges to read_only (subset)" do
      base = Profile.new!(%{sandbox_profile: :workspace_only})
      override = Profile.new!(%{sandbox_profile: :read_only})
      merged = Profile.merge(base, override)

      # read_only is at_least as restrictive as workspace_only
      assert merged.sandbox_profile == :read_only
    end

    test "workspace_only + no_network merges to no_network (subset)" do
      base = Profile.new!(%{sandbox_profile: :workspace_only})
      override = Profile.new!(%{sandbox_profile: :no_network})
      merged = Profile.merge(base, override)

      # no_network is at_least as restrictive as workspace_only
      assert merged.sandbox_profile == :no_network
    end

    test "read_only + locked_down merges to locked_down (subset)" do
      base = Profile.new!(%{sandbox_profile: :read_only})
      override = Profile.new!(%{sandbox_profile: :locked_down})
      merged = Profile.merge(base, override)

      assert merged.sandbox_profile == :locked_down
    end
  end
end
