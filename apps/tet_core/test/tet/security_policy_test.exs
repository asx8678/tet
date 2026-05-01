defmodule Tet.SecurityPolicyTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Tet.SecurityPolicy
  alias Tet.SecurityPolicy.Profile
  alias Tet.SecurityPolicy.Evaluator

  describe "approval_modes/0" do
    test "returns four modes from most to least permissive" do
      assert SecurityPolicy.approval_modes() ==
               [:auto_approve, :suggest_approve, :require_approve, :always_deny]
    end
  end

  describe "sandbox_profiles/0" do
    test "returns five profiles" do
      assert SecurityPolicy.sandbox_profiles() ==
               [:unrestricted, :workspace_only, :read_only, :no_network, :locked_down]
    end
  end

  # --- Approval mode gating ---

  describe "approval mode gates actions" do
    test "auto_approve allows read with no deny globs" do
      profile = Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :unrestricted})
      assert :allowed = SecurityPolicy.check(:read, %{mcp_category: :read}, profile)
    end

    test "suggest_approve returns needs_approval" do
      profile = Profile.new!(%{approval_mode: :suggest_approve, sandbox_profile: :unrestricted})

      assert {:needs_approval, :suggest_approve} =
               SecurityPolicy.check(:read, %{mcp_category: :read}, profile)
    end

    test "require_approve returns needs_approval" do
      profile = Profile.new!(%{approval_mode: :require_approve, sandbox_profile: :unrestricted})

      assert {:needs_approval, :approval_mode_require_approve} =
               SecurityPolicy.check(:read, %{mcp_category: :read}, profile)
    end

    test "always_deny short-circuits to denied" do
      profile = Profile.new!(%{approval_mode: :always_deny, sandbox_profile: :locked_down})
      assert {:denied, :always_deny_mode} = SecurityPolicy.check(:read, %{}, profile)
    end

    test "always_deny blocks even with permissive glob" do
      profile =
        Profile.new!(%{
          approval_mode: :always_deny,
          sandbox_profile: :unrestricted,
          allow_paths: ["**"]
        })

      assert {:denied, :always_deny_mode} =
               SecurityPolicy.check(:read, %{path: "/anything"}, profile)
    end
  end

  # --- Sandbox profile restrictions ---

  describe "sandbox profiles restrict access" do
    test "unrestricted allows any path" do
      profile = Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :unrestricted})
      assert :allowed = SecurityPolicy.check(:read, %{path: "/etc/passwd"}, profile)
    end

    test "workspace_only denies paths outside workspace" do
      profile = Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :workspace_only})

      assert {:denied, :sandbox_workspace_only} =
               SecurityPolicy.check(
                 :read,
                 %{path: "/etc/passwd", workspace_root: "/workspace"},
                 profile
               )
    end

    test "workspace_only allows paths inside workspace" do
      profile = Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :workspace_only})

      assert :allowed =
               SecurityPolicy.check(
                 :read,
                 %{path: "/workspace/src/file.ex", workspace_root: "/workspace"},
                 profile
               )
    end

    test "read_only denies write actions" do
      profile = Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :read_only})

      assert {:denied, :sandbox_read_only} =
               SecurityPolicy.check(
                 :write,
                 %{path: "/workspace/file.ex", workspace_root: "/workspace"},
                 profile
               )
    end

    test "read_only allows read actions in workspace" do
      profile = Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :read_only})

      assert :allowed =
               SecurityPolicy.check(
                 :read,
                 %{path: "/workspace/file.ex", workspace_root: "/workspace"},
                 profile
               )
    end

    test "no_network denies network actions" do
      profile = Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :no_network})

      assert {:denied, :sandbox_no_network} =
               SecurityPolicy.check(:network, %{}, profile)
    end

    test "no_network denies fetch actions" do
      profile = Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :no_network})

      assert {:denied, :sandbox_no_network} =
               SecurityPolicy.check(:fetch, %{}, profile)
    end

    test "no_network allows workspace-only filesystem" do
      profile = Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :no_network})

      assert :allowed =
               SecurityPolicy.check(
                 :read,
                 %{path: "/workspace/file.ex", workspace_root: "/workspace"},
                 profile
               )
    end

    test "locked_down denies everything" do
      profile = Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :locked_down})

      assert {:denied, :sandbox_locked_down} =
               SecurityPolicy.check(:read, %{path: "/workspace/file.ex"}, profile)
    end
  end

  # --- Deny/allow precedence ---

  describe "deny always beats allow" do
    test "deny glob overrides allow path" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          deny_globs: ["/etc/**"],
          allow_paths: ["**"]
        })

      # Path matches both deny and allow → denied
      assert {:denied, :denied_by_glob} =
               SecurityPolicy.check(:read, %{path: "/etc/passwd"}, profile)
    end

    test "allow path works when no deny glob matches" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          deny_globs: ["/etc/**"],
          allow_paths: ["/workspace/**"]
        })

      assert :allowed =
               SecurityPolicy.check(:read, %{path: "/workspace/file.ex"}, profile)
    end

    test "path not in allow_paths needs approval" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          allow_paths: ["/workspace/**"]
        })

      # /tmp/file.ex is not in allow_paths
      assert {:needs_approval, :not_in_allow_paths} =
               SecurityPolicy.check(:read, %{path: "/tmp/file.ex"}, profile)
    end

    test "multiple deny globs — any match blocks" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          deny_globs: ["/etc/**", "/var/log/**"],
          allow_paths: ["**"]
        })

      assert {:denied, :denied_by_glob} =
               SecurityPolicy.check(:read, %{path: "/var/log/syslog"}, profile)
    end

    test "deny glob with wildcard segments" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          deny_globs: ["**/secrets/**"],
          allow_paths: ["**"]
        })

      assert {:denied, :denied_by_glob} =
               SecurityPolicy.check(:read, %{path: "/workspace/secrets/key.pem"}, profile)
    end

    test "empty deny_globs does not block" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          deny_globs: [],
          allow_paths: ["**"]
        })

      assert :allowed = SecurityPolicy.check(:read, %{path: "/any/path"}, profile)
    end
  end

  # --- Glob matching ---

  describe "glob matching" do
    test "single star matches one segment" do
      assert Evaluator.denied_by_glob?("/etc/passwd", ["/etc/*"])
      refute Evaluator.denied_by_glob?("/etc/sub/passwd", ["/etc/*"])
    end

    test "double star matches multiple segments" do
      assert Evaluator.denied_by_glob?("/etc/sub/deep/passwd", ["/etc/**"])
      assert Evaluator.denied_by_glob?("/etc/passwd", ["/etc/**"])
    end

    test "question mark matches single character" do
      assert Evaluator.denied_by_glob?("/etc/passwd", ["/etc/pass?d"])
      # Two question marks match two characters
      assert Evaluator.denied_by_glob?("/etc/passwd", ["/etc/pass??"])
      refute Evaluator.denied_by_glob?("/etc/passwd", ["/etc/pass???"])
    end
  end

  # --- MCP trust levels ---

  describe "MCP trust levels restrict tool access" do
    test "category at or below trust level is allowed" do
      profile = Profile.new!(%{approval_mode: :auto_approve, mcp_trust: :write})
      assert :allowed = Evaluator.check_mcp(:read, profile)
      assert :allowed = Evaluator.check_mcp(:write, profile)
    end

    test "category above trust level needs approval" do
      profile = Profile.new!(%{approval_mode: :auto_approve, mcp_trust: :read})

      assert {:needs_approval, {:mcp_trust_exceeded, %{category: :write, max_allowed: :read}}} =
               Evaluator.check_mcp(:write, profile)
    end

    test "shell is blocked when trust is read" do
      profile = Profile.new!(%{approval_mode: :auto_approve, mcp_trust: :read})

      assert {:needs_approval, {:mcp_trust_exceeded, %{category: :shell, max_allowed: :read}}} =
               Evaluator.check_mcp(:shell, profile)
    end

    test "admin trust allows everything" do
      profile = Profile.new!(%{approval_mode: :auto_approve, mcp_trust: :admin})
      assert :allowed = Evaluator.check_mcp(:read, profile)
      assert :allowed = Evaluator.check_mcp(:write, profile)
      assert :allowed = Evaluator.check_mcp(:shell, profile)
      assert :allowed = Evaluator.check_mcp(:network, profile)
      assert :allowed = Evaluator.check_mcp(:admin, profile)
    end

    test "unknown category is denied" do
      profile = Profile.new!(%{approval_mode: :auto_approve, mcp_trust: :admin})
      assert {:denied, :unknown_mcp_category} = Evaluator.check_mcp(:nuclear, profile)
    end

    test "MCP context in check/3 is evaluated" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          mcp_trust: :read
        })

      assert {:needs_approval, {:mcp_trust_exceeded, _}} =
               SecurityPolicy.check(:write, %{mcp_category: :write}, profile)
    end
  end

  # --- Remote trust levels ---

  describe "remote trust levels restrict remote operations" do
    test "local trust allows trusted_remote operations" do
      profile = Profile.new!(%{approval_mode: :auto_approve, remote_trust: :trusted_remote})

      assert :allowed = Evaluator.check_remote(:execute_commands, :trusted_remote, profile)
    end

    test "untrusted_remote is denied when profile requires trusted_remote" do
      profile = Profile.new!(%{approval_mode: :auto_approve, remote_trust: :trusted_remote})

      assert {:denied,
              {:remote_trust_insufficient,
               %{required: :trusted_remote, actual: :untrusted_remote}}} =
               Evaluator.check_remote(:execute_commands, :untrusted_remote, profile)
    end

    test "local trust satisfies local requirement" do
      profile = Profile.new!(%{approval_mode: :auto_approve, remote_trust: :local})

      assert :allowed = Evaluator.check_remote(:install_packages, :local, profile)
    end

    test "unknown remote operation is denied" do
      profile = Profile.new!(%{approval_mode: :auto_approve, remote_trust: :local})

      assert {:denied, {:unknown_remote_operation, :teleport}} =
               Evaluator.check_remote(:teleport, :local, profile)
    end

    test "remote context in check/3 is evaluated" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          remote_trust: :local
        })

      assert {:denied, {:remote_trust_insufficient, _}} =
               SecurityPolicy.check(
                 :deploy,
                 %{remote_operation: :install_packages, remote_trust_level: :trusted_remote},
                 profile
               )
    end
  end

  # --- Repair operations ---

  describe "repair operations require proper approval" do
    test "retry is auto-approved by default" do
      profile = Profile.new!(%{approval_mode: :auto_approve})
      assert :allowed = Evaluator.check_repair(:retry, profile)
    end

    test "fallback needs suggest_approve by default" do
      profile = Profile.new!(%{approval_mode: :suggest_approve})
      # suggest_approve + suggest_approve → effective 2 → needs approval
      assert {:needs_approval, :suggest_approve} = Evaluator.check_repair(:fallback, profile)
    end

    test "patch needs require_approve by default" do
      profile = Profile.new!(%{approval_mode: :suggest_approve})

      assert {:needs_approval,
              {:repair_approval_required, %{strategy: :patch, required: :require_approve}}} =
               Evaluator.check_repair(:patch, profile)
    end

    test "human is always denied by default" do
      profile = Profile.new!(%{approval_mode: :auto_approve})

      assert {:denied, {:repair_always_deny, :human}} =
               Evaluator.check_repair(:human, profile)
    end

    test "always_deny mode blocks all repairs" do
      profile = Profile.new!(%{approval_mode: :always_deny})
      assert {:denied, :always_deny_mode} = Evaluator.check_repair(:retry, profile)
    end

    test "unknown strategy is denied" do
      profile = Profile.new!(%{approval_mode: :auto_approve})
      assert {:denied, :unknown_repair_strategy} = Evaluator.check_repair(:singularity, profile)
    end

    test "custom repair approval mapping works" do
      profile =
        Profile.new!(%{
          approval_mode: :require_approve,
          repair_approval: %{
            retry: :require_approve,
            fallback: :always_deny,
            patch: :always_deny,
            human: :always_deny
          }
        })

      # mode=require_approve (1) + retry=require_approve (1) → effective 1 → needs approval
      assert {:needs_approval,
              {:repair_approval_required, %{strategy: :retry, required: :require_approve}}} =
               Evaluator.check_repair(:retry, profile)

      # fallback is always_deny → denied
      assert {:denied, {:repair_always_deny, :fallback}} =
               Evaluator.check_repair(:fallback, profile)
    end

    test "repair context in check/3 is evaluated" do
      profile = Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :unrestricted})

      assert {:denied, {:repair_always_deny, :human}} =
               SecurityPolicy.check(:repair, %{repair_strategy: :human}, profile)
    end
  end

  # --- Policy composition ---

  describe "policy composition and inheritance" do
    test "merge picks more restrictive security values" do
      base = Profile.new!(%{approval_mode: :require_approve, sandbox_profile: :workspace_only})
      override = Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :read_only})

      merged = SecurityPolicy.merge_profiles(base, override)
      assert merged.approval_mode == :require_approve
      assert merged.sandbox_profile == :read_only
    end

    test "merge combines deny_globs" do
      base = Profile.new!(%{deny_globs: ["/etc/**"]})
      override = Profile.new!(%{deny_globs: ["/var/**"]})

      merged = SecurityPolicy.merge_profiles(base, override)
      assert "/etc/**" in merged.deny_globs
      assert "/var/**" in merged.deny_globs
    end

    test "merge allow_paths intersection when both non-nil" do
      base = Profile.new!(%{allow_paths: ["/old/**"]})
      override = Profile.new!(%{allow_paths: ["/new/**"]})

      merged = SecurityPolicy.merge_profiles(base, override)
      # Disjoint lists → empty intersection → allow nothing
      assert merged.allow_paths == []
    end

    test "merge keeps base allow_paths when override has no restriction (nil)" do
      base = Profile.new!(%{allow_paths: ["/old/**"]})
      override = Profile.new!(%{})

      merged = SecurityPolicy.merge_profiles(base, override)
      assert merged.allow_paths == ["/old/**"]
    end

    test "merge combines repair_approval over full strategy set (missing = always_deny)" do
      base = Profile.new!(%{repair_approval: %{retry: :auto_approve, fallback: :suggest_approve}})
      override = Profile.new!(%{repair_approval: %{fallback: :require_approve}})

      merged = SecurityPolicy.merge_profiles(base, override)

      # retry: base=auto_approve, override missing → always_deny → more restrictive = always_deny
      assert merged.repair_approval.retry == :always_deny
      # fallback: require_approve more restrictive than suggest_approve
      assert merged.repair_approval.fallback == :require_approve
    end

    test "merge combines metadata with override winning" do
      base = Profile.new!(%{metadata: %{source: "base", version: "1"}})
      override = Profile.new!(%{metadata: %{source: "override", extra: "yes"}})

      merged = SecurityPolicy.merge_profiles(base, override)
      assert merged.metadata.source == "override"
      assert merged.metadata.version == "1"
      assert merged.metadata.extra == "yes"
    end
  end

  # --- Preset profiles ---

  describe "task_presets/0" do
    test "returns all six task categories" do
      presets = SecurityPolicy.task_presets()

      for task <- [:researching, :planning, :acting, :verifying, :debugging, :documenting] do
        assert Map.has_key?(presets, task), "missing task preset: #{task}"
      end
    end

    test "researching is read-only" do
      p = SecurityPolicy.task_presets().researching
      assert p.approval_mode == :suggest_approve
      assert p.sandbox_profile == :read_only
      assert p.mcp_trust == :read
    end

    test "acting is most permissive" do
      p = SecurityPolicy.task_presets().acting
      assert p.approval_mode == :auto_approve
      assert p.sandbox_profile == :workspace_only
      assert p.mcp_trust == :write
      assert p.remote_trust == :trusted_remote
    end

    test "no preset gets shell mcp_trust" do
      for {_task, p} <- SecurityPolicy.task_presets() do
        refute p.mcp_trust in [:shell, :admin],
               "no task should get shell/admin mcp_trust by default"
      end
    end
  end

  # --- Built-in profiles ---

  describe "built-in profiles" do
    test "default is conservative" do
      profile = SecurityPolicy.default_profile()
      assert profile.approval_mode == :require_approve
      assert profile.sandbox_profile == :workspace_only
    end

    test "permissive allows everything" do
      profile = SecurityPolicy.permissive_profile()
      assert profile.approval_mode == :auto_approve
      assert profile.sandbox_profile == :unrestricted
      assert profile.mcp_trust == :admin
      assert profile.remote_trust == :local
    end

    test "locked_down denies everything" do
      profile = SecurityPolicy.locked_down_profile()
      assert profile.approval_mode == :always_deny
      assert profile.sandbox_profile == :locked_down
    end
  end

  # --- Matrix introspection ---

  describe "matrix/1" do
    test "returns complete policy overview" do
      profile = SecurityPolicy.default_profile()
      matrix = SecurityPolicy.matrix(profile)

      assert matrix.approval_mode.mode == :require_approve
      assert matrix.sandbox.profile == :workspace_only
      assert matrix.deny_allow.rule == "deny always beats allow"
      assert is_map(matrix.repair_approval)
    end
  end

  # --- Batch evaluation ---

  describe "check_all/2" do
    test "batch evaluates multiple actions" do
      profile = Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :unrestricted})

      actions = [
        {:read, %{mcp_category: :read}},
        {:write, %{mcp_category: :write}}
      ]

      results = SecurityPolicy.check_all(actions, profile)
      assert length(results) == 2
      assert {_, :allowed} = Enum.at(results, 0)
    end
  end

  # --- Approval mode dimension hard-denies override needs_approval ---

  describe "hard deny from dimension overrides needs_approval from approval mode" do
    test "sandbox deny overrides suggest_approve" do
      profile = Profile.new!(%{approval_mode: :suggest_approve, sandbox_profile: :locked_down})

      # suggest_approve would normally return {:needs_approval, :suggest_approve}
      # but locked_down sandbox gives a hard deny which takes priority
      assert {:denied, :sandbox_locked_down} =
               SecurityPolicy.check(:read, %{path: "/anything"}, profile)
    end

    test "deny glob overrides needs_approval from require_approve mode" do
      profile =
        Profile.new!(%{
          approval_mode: :require_approve,
          sandbox_profile: :unrestricted,
          deny_globs: ["/secret/**"],
          allow_paths: ["/workspace/**"]
        })

      # Path in deny glob → hard deny, even though mode says needs_approval
      assert {:denied, :denied_by_glob} =
               SecurityPolicy.check(:read, %{path: "/secret/key"}, profile)
    end
  end
end
