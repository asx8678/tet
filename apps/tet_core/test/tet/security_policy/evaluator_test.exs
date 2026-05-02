defmodule Tet.SecurityPolicy.EvaluatorTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Tet.SecurityPolicy.Evaluator
  alias Tet.SecurityPolicy.Profile

  # --- check/3 comprehensive ---

  describe "check/3 with always_deny" do
    test "always_deny short-circuits regardless of context" do
      profile = Profile.new!(%{approval_mode: :always_deny, sandbox_profile: :unrestricted})

      assert {:denied, :always_deny_mode} =
               Evaluator.check(:read, %{mcp_category: :read}, profile)
    end

    test "always_deny ignores allow_paths" do
      profile =
        Profile.new!(%{
          approval_mode: :always_deny,
          sandbox_profile: :unrestricted,
          allow_paths: ["**"]
        })

      assert {:denied, :always_deny_mode} = Evaluator.check(:read, %{path: "/any"}, profile)
    end
  end

  describe "check/3 with auto_approve" do
    test "allows read with no constraints" do
      profile = Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :unrestricted})
      assert :allowed = Evaluator.check(:read, %{mcp_category: :read}, profile)
    end

    test "denies via sandbox constraints" do
      profile = Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :read_only})

      assert {:denied, :sandbox_read_only} =
               Evaluator.check(
                 :write,
                 %{path: "/workspace/f.ex", workspace_root: "/workspace"},
                 profile
               )
    end

    test "denies via deny glob" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          deny_globs: ["/secret/**"]
        })

      assert {:denied, :denied_by_glob} =
               Evaluator.check(:read, %{path: "/secret/key"}, profile)
    end

    test "needs approval for MCP category above trust" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          mcp_trust: :read
        })

      assert {:needs_approval, {:mcp_trust_exceeded, _}} =
               Evaluator.check(:execute, %{mcp_category: :shell}, profile)
    end
  end

  describe "check/3 with require_approve" do
    test "returns needs_approval when no hard deny applies" do
      profile = Profile.new!(%{approval_mode: :require_approve, sandbox_profile: :unrestricted})

      assert {:needs_approval, :approval_mode_require_approve} =
               Evaluator.check(:read, %{mcp_category: :read}, profile)
    end

    test "hard deny from sandbox overrides needs_approval" do
      profile = Profile.new!(%{approval_mode: :require_approve, sandbox_profile: :locked_down})

      assert {:denied, :sandbox_locked_down} =
               Evaluator.check(:read, %{path: "/workspace/f"}, profile)
    end
  end

  # --- check_approval_mode/1 ---

  describe "check_approval_mode/1" do
    test "auto_approve returns allowed" do
      assert :allowed = Evaluator.check_approval_mode(:auto_approve)
    end

    test "suggest_approve returns needs_approval" do
      assert {:needs_approval, :suggest_approve} = Evaluator.check_approval_mode(:suggest_approve)
    end

    test "require_approve returns needs_approval" do
      assert {:needs_approval, :approval_mode_require_approve} =
               Evaluator.check_approval_mode(:require_approve)
    end

    test "always_deny returns denied" do
      assert {:denied, :always_deny_mode} = Evaluator.check_approval_mode(:always_deny)
    end
  end

  # --- check_mcp/2 ---

  describe "check_mcp/2" do
    test "read category allowed when mcp_trust is read" do
      profile = Profile.new!(%{mcp_trust: :read})
      assert :allowed = Evaluator.check_mcp(:read, profile)
    end

    test "write category denied when mcp_trust is read" do
      profile = Profile.new!(%{mcp_trust: :read})

      assert {:needs_approval, {:mcp_trust_exceeded, %{category: :write, max_allowed: :read}}} =
               Evaluator.check_mcp(:write, profile)
    end

    test "shell needs approval when mcp_trust is write" do
      profile = Profile.new!(%{mcp_trust: :write})

      assert {:needs_approval, {:mcp_trust_exceeded, %{category: :shell, max_allowed: :write}}} =
               Evaluator.check_mcp(:shell, profile)
    end

    test "admin allowed when mcp_trust is admin" do
      profile = Profile.new!(%{mcp_trust: :admin})
      assert :allowed = Evaluator.check_mcp(:admin, profile)
    end

    test "unknown category denied" do
      profile = Profile.new!(%{mcp_trust: :admin})
      assert {:denied, :unknown_mcp_category} = Evaluator.check_mcp(:time_travel, profile)
    end

    test "all categories at or below mcp_trust are allowed" do
      for trust <- [:read, :write, :network, :shell, :admin] do
        profile = Profile.new!(%{mcp_trust: trust})

        for cat <- Tet.Mcp.Classification.categories() do
          result = Evaluator.check_mcp(cat, profile)

          if Tet.Mcp.Classification.risk_index(cat) <= Tet.Mcp.Classification.risk_index(trust) do
            assert result == :allowed, "Expected #{cat} to be allowed with mcp_trust=#{trust}"
          end
        end
      end
    end
  end

  # --- check_remote/3 ---

  describe "check_remote/3" do
    test "allowed when trust level meets requirement" do
      profile = Profile.new!(%{remote_trust: :trusted_remote})

      assert :allowed = Evaluator.check_remote(:execute_commands, :trusted_remote, profile)
    end

    test "denied when trust level is insufficient" do
      profile = Profile.new!(%{remote_trust: :trusted_remote})

      assert {:denied,
              {:remote_trust_insufficient,
               %{required: :trusted_remote, actual: :untrusted_remote}}} =
               Evaluator.check_remote(:execute_commands, :untrusted_remote, profile)
    end

    test "local trust satisfies local requirement" do
      profile = Profile.new!(%{remote_trust: :local})
      assert :allowed = Evaluator.check_remote(:install_packages, :local, profile)
    end

    test "trusted_remote denied for local-only operation" do
      profile = Profile.new!(%{remote_trust: :local})

      # trusted_remote doesn't meet profile's local requirement
      assert {:denied, {:remote_trust_insufficient, _}} =
               Evaluator.check_remote(:install_packages, :trusted_remote, profile)
    end

    test "invalid trust level denied" do
      profile = Profile.new!(%{remote_trust: :local})

      assert {:denied, :invalid_remote_trust_level} =
               Evaluator.check_remote(:read_status, :sketchy, profile)
    end

    test "unknown operation denied" do
      profile = Profile.new!(%{remote_trust: :local})

      assert {:denied, {:unknown_remote_operation, :teleport}} =
               Evaluator.check_remote(:teleport, :local, profile)
    end
  end

  # --- check_sandbox/3 ---

  describe "check_sandbox/3" do
    test "unrestricted allows everything" do
      profile = Profile.new!(%{sandbox_profile: :unrestricted})
      assert :allowed = Evaluator.check_sandbox(:write, %{path: "/etc/passwd"}, profile)
    end

    test "workspace_only denies outside workspace" do
      profile = Profile.new!(%{sandbox_profile: :workspace_only})

      assert {:denied, :sandbox_workspace_only} =
               Evaluator.check_sandbox(
                 :read,
                 %{path: "/etc/passwd", workspace_root: "/workspace"},
                 profile
               )
    end

    test "workspace_only allows inside workspace" do
      profile = Profile.new!(%{sandbox_profile: :workspace_only})

      assert :allowed =
               Evaluator.check_sandbox(
                 :read,
                 %{path: "/workspace/file.ex", workspace_root: "/workspace"},
                 profile
               )
    end

    test "read_only denies write" do
      profile = Profile.new!(%{sandbox_profile: :read_only})

      assert {:denied, :sandbox_read_only} =
               Evaluator.check_sandbox(
                 :write,
                 %{path: "/workspace/f.ex", workspace_root: "/workspace"},
                 profile
               )
    end

    test "read_only allows read in workspace" do
      profile = Profile.new!(%{sandbox_profile: :read_only})

      assert :allowed =
               Evaluator.check_sandbox(
                 :read,
                 %{path: "/workspace/f.ex", workspace_root: "/workspace"},
                 profile
               )
    end

    test "read_only denies write outside workspace" do
      profile = Profile.new!(%{sandbox_profile: :read_only})

      # Write action → read_only deny fires before workspace check
      assert {:denied, :sandbox_read_only} =
               Evaluator.check_sandbox(
                 :write,
                 %{path: "/etc/passwd", workspace_root: "/workspace"},
                 profile
               )
    end

    test "no_network denies network actions" do
      profile = Profile.new!(%{sandbox_profile: :no_network})

      assert {:denied, :sandbox_no_network} = Evaluator.check_sandbox(:network, %{}, profile)
    end

    test "no_network denies http_request" do
      profile = Profile.new!(%{sandbox_profile: :no_network})

      assert {:denied, :sandbox_no_network} = Evaluator.check_sandbox(:http_request, %{}, profile)
    end

    test "locked_down denies everything" do
      profile = Profile.new!(%{sandbox_profile: :locked_down})

      assert {:denied, :sandbox_locked_down} =
               Evaluator.check_sandbox(:read, %{path: "/safe"}, profile)
    end

    test "workspace_only with exact workspace root path matches" do
      profile = Profile.new!(%{sandbox_profile: :workspace_only})

      assert :allowed =
               Evaluator.check_sandbox(
                 :read,
                 %{path: "/workspace", workspace_root: "/workspace"},
                 profile
               )
    end

    test "workspace_only denies paths containing null bytes" do
      profile = Profile.new!(%{sandbox_profile: :workspace_only})

      assert {:denied, :sandbox_null_byte_in_path} =
               Evaluator.check_sandbox(
                 :read,
                 %{path: "/workspace/safe.txt\0../../etc/passwd", workspace_root: "/workspace"},
                 profile
               )
    end

    test "read_only denies paths containing null bytes" do
      profile = Profile.new!(%{sandbox_profile: :read_only})

      assert {:denied, :sandbox_null_byte_in_path} =
               Evaluator.check_sandbox(
                 :read,
                 %{path: "/workspace/file.ex\0.jpg", workspace_root: "/workspace"},
                 profile
               )
    end

    test "no_network denies paths containing null bytes" do
      profile = Profile.new!(%{sandbox_profile: :no_network})

      assert {:denied, :sandbox_null_byte_in_path} =
               Evaluator.check_sandbox(
                 :read,
                 %{path: "/workspace/safe\0evil", workspace_root: "/workspace"},
                 profile
               )
    end

    test "unrestricted allows paths with null bytes (no sandbox constraints)" do
      profile = Profile.new!(%{sandbox_profile: :unrestricted})

      assert :allowed =
               Evaluator.check_sandbox(
                 :read,
                 %{path: "/workspace/safe\0evil", workspace_root: "/workspace"},
                 profile
               )
    end
  end

  # --- check_repair/2 ---

  describe "check_repair/2" do
    test "retry allowed with auto_approve" do
      profile = Profile.new!(%{approval_mode: :auto_approve})
      assert :allowed = Evaluator.check_repair(:retry, profile)
    end

    test "fallback needs approval with suggest_approve mode" do
      profile = Profile.new!(%{approval_mode: :suggest_approve})
      # suggest_approve (2) + suggest_approve (2) = effective 2 → needs approval
      assert {:needs_approval, :suggest_approve} = Evaluator.check_repair(:fallback, profile)
    end

    test "patch needs approval with suggest_approve mode" do
      profile = Profile.new!(%{approval_mode: :suggest_approve})

      assert {:needs_approval,
              {:repair_approval_required, %{strategy: :patch, required: :require_approve}}} =
               Evaluator.check_repair(:patch, profile)
    end

    test "human always denied by default" do
      profile = Profile.new!(%{approval_mode: :auto_approve})
      assert {:denied, {:repair_always_deny, :human}} = Evaluator.check_repair(:human, profile)
    end

    test "always_deny mode blocks even retry" do
      profile = Profile.new!(%{approval_mode: :always_deny})
      assert {:denied, :always_deny_mode} = Evaluator.check_repair(:retry, profile)
    end

    test "unknown strategy denied" do
      profile = Profile.new!(%{approval_mode: :auto_approve})
      assert {:denied, :unknown_repair_strategy} = Evaluator.check_repair(:magic, profile)
    end

    test "custom repair approval with fallback at always_deny" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          repair_approval: %{
            retry: :auto_approve,
            fallback: :always_deny,
            patch: :always_deny,
            human: :always_deny
          }
        })

      assert {:denied, {:repair_always_deny, :fallback}} =
               Evaluator.check_repair(:fallback, profile)
    end

    test "fallback needs approval when mode is auto_approve but repair requires suggest_approve" do
      # auto_approve (3) + suggest_approve (2) = min → effective 2 → needs approval
      profile = Profile.new!(%{approval_mode: :auto_approve})
      assert {:needs_approval, :suggest_approve} = Evaluator.check_repair(:fallback, profile)
    end

    test "patch requires require_approve, suggest_approve mode not enough" do
      profile = Profile.new!(%{approval_mode: :suggest_approve})

      assert {:needs_approval,
              {:repair_approval_required, %{strategy: :patch, required: :require_approve}}} =
               Evaluator.check_repair(:patch, profile)
    end
  end

  # --- Glob matching ---

  describe "denied_by_glob?/2" do
    test "single star matches one segment" do
      assert Evaluator.denied_by_glob?("/etc/passwd", ["/etc/*"])
    end

    test "single star does not match multiple segments" do
      refute Evaluator.denied_by_glob?("/etc/sub/passwd", ["/etc/*"])
    end

    test "double star matches zero or more segments" do
      assert Evaluator.denied_by_glob?("/etc/passwd", ["/etc/**"])
      assert Evaluator.denied_by_glob?("/etc/sub/deep/passwd", ["/etc/**"])
    end

    test "no match returns false" do
      refute Evaluator.denied_by_glob?("/workspace/file.ex", ["/etc/**"])
    end

    test "empty deny_globs never denies" do
      refute Evaluator.denied_by_glob?("/anything", [])
    end

    test "multiple globs — any match denies" do
      assert Evaluator.denied_by_glob?("/var/log/syslog", ["/etc/**", "/var/log/**"])
    end

    test "normalises backslashes" do
      assert Evaluator.denied_by_glob?("C:/Windows/System32/config", ["C:/Windows/**"])
    end
  end

  describe "allowed_by_path?/2" do
    test "matching allow path returns true" do
      assert Evaluator.allowed_by_path?("/workspace/file.ex", ["/workspace/**"])
    end

    test "non-matching path returns false" do
      refute Evaluator.allowed_by_path?("/etc/passwd", ["/workspace/**"])
    end

    test "empty allow_paths returns false" do
      refute Evaluator.allowed_by_path?("/anything", [])
    end

    test "wildcard double star" do
      assert Evaluator.allowed_by_path?("/workspace/deep/nested/file.ex", ["/workspace/**"])
    end
  end

  # --- check_all/2 ---

  describe "check_all/2" do
    test "batch evaluates" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          mcp_trust: :admin
        })

      actions = [
        {:read, %{mcp_category: :read}},
        {:write, %{mcp_category: :write}}
      ]

      results = Evaluator.check_all(actions, profile)
      assert length(results) == 2

      {_, decision1} = Enum.at(results, 0)
      {_, decision2} = Enum.at(results, 1)

      assert decision1 == :allowed
      assert decision2 == :allowed
    end
  end

  # --- Dimension interaction ---

  describe "dimension interaction: deny glob beats allow path" do
    test "explicit deny on secret path despite wildcard allow" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          deny_globs: ["**/secret/**"],
          allow_paths: ["**"]
        })

      assert {:denied, :denied_by_glob} =
               Evaluator.check(:read, %{path: "/workspace/secret/key.pem"}, profile)
    end
  end

  describe "dimension interaction: sandbox + MCP" do
    test "both sandbox and MCP must pass" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :workspace_only,
          mcp_trust: :read
        })

      # sandbox allows, but MCP blocks shell
      assert {:needs_approval, {:mcp_trust_exceeded, _}} =
               Evaluator.check(
                 :shell,
                 %{
                   path: "/workspace/file.ex",
                   mcp_category: :shell,
                   workspace_root: "/workspace"
                 },
                 profile
               )
    end

    test "sandbox deny takes priority over MCP allow" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :workspace_only,
          mcp_trust: :admin
        })

      # MCP allows everything, but sandbox blocks out-of-workspace path
      assert {:denied, :sandbox_workspace_only} =
               Evaluator.check(
                 :read,
                 %{
                   path: "/etc/passwd",
                   mcp_category: :read,
                   workspace_root: "/workspace"
                 },
                 profile
               )
    end
  end

  describe "dimension interaction: remote + approval mode" do
    test "always_deny overrides everything including remote" do
      profile =
        Profile.new!(%{
          approval_mode: :always_deny,
          remote_trust: :local
        })

      assert {:denied, :always_deny_mode} =
               Evaluator.check(
                 :deploy,
                 %{remote_operation: :read_status, remote_trust_level: :local},
                 profile
               )
    end
  end

  # --- SECURITY: Path traversal prevention ---

  describe "path traversal prevention" do
    test "deny /workspace/../etc/passwd under workspace_only" do
      profile = Profile.new!(%{sandbox_profile: :workspace_only})

      assert {:denied, :sandbox_workspace_only} =
               Evaluator.check_sandbox(
                 :read,
                 %{path: "/workspace/../etc/passwd", workspace_root: "/workspace"},
                 profile
               )
    end

    test "deny nested .. traversal" do
      profile = Profile.new!(%{sandbox_profile: :workspace_only})

      assert {:denied, :sandbox_workspace_only} =
               Evaluator.check_sandbox(
                 :read,
                 %{path: "/workspace/sub/../../etc/passwd", workspace_root: "/workspace"},
                 profile
               )
    end

    test "deny deeply nested .. traversal" do
      profile = Profile.new!(%{sandbox_profile: :workspace_only})

      assert {:denied, :sandbox_workspace_only} =
               Evaluator.check_sandbox(
                 :read,
                 %{path: "/workspace/a/b/../../../etc/shadow", workspace_root: "/workspace"},
                 profile
               )
    end

    test "allow normal workspace path after canonicalization" do
      profile = Profile.new!(%{sandbox_profile: :workspace_only})

      assert :allowed =
               Evaluator.check_sandbox(
                 :read,
                 %{path: "/workspace/sub/../file.ex", workspace_root: "/workspace"},
                 profile
               )
    end

    test "deny glob catches path traversal with .. segments" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          deny_globs: ["/etc/**"]
        })

      # /workspace/../etc/passwd canonicalises to /etc/passwd
      assert {:denied, :denied_by_glob} =
               Evaluator.check(:read, %{path: "/workspace/../etc/passwd"}, profile)
    end

    test "allow path check canonicalises .. segments" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          allow_paths: ["/workspace/**"]
        })

      # /workspace/sub/../file.ex canonicalises to /workspace/file.ex
      assert :allowed =
               Evaluator.check(:read, %{path: "/workspace/sub/../file.ex"}, profile)
    end

    test "deny glob blocks /workspace/../etc/passwd via glob" do
      _profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          deny_globs: ["/etc/**"]
        })

      assert Evaluator.denied_by_glob?("/workspace/../etc/passwd", ["/etc/**"])
    end

    test "allow path does not match /workspace/../etc/passwd for /workspace/**" do
      refute Evaluator.allowed_by_path?("/workspace/../etc/passwd", ["/workspace/**"])
    end
  end

  # --- SECURITY: MCP dimension fail-closed ---

  describe "MCP dimension fail-closed" do
    test "unknown MCP category denied when present" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          mcp_trust: :admin
        })

      assert {:denied, :unknown_mcp_category} =
               Evaluator.check(:read, %{mcp_category: :time_travel}, profile)
    end

    test "non-atom MCP category denied" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          mcp_trust: :admin
        })

      assert {:denied, :unknown_mcp_category} =
               Evaluator.check(:read, %{mcp_category: "read"}, profile)
    end

    test "nil MCP category denied" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          mcp_trust: :admin
        })

      assert {:denied, :unknown_mcp_category} =
               Evaluator.check(:read, %{mcp_category: nil}, profile)
    end

    test "no MCP category in context is allowed" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          mcp_trust: :admin
        })

      assert :allowed = Evaluator.check(:read, %{}, profile)
    end
  end

  # --- SECURITY: Remote dimension fail-closed ---

  describe "remote dimension fail-closed" do
    test "missing remote_trust_level denied" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          remote_trust: :local
        })

      assert {:denied, :missing_remote_trust_level} =
               Evaluator.check(:deploy, %{remote_operation: :read_status}, profile)
    end

    test "missing remote_operation denied" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          remote_trust: :local
        })

      assert {:denied, :missing_remote_operation} =
               Evaluator.check(:deploy, %{remote_trust_level: :local}, profile)
    end

    test "invalid remote context denied" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          remote_trust: :local
        })

      assert {:denied, :invalid_remote_context} =
               Evaluator.check(
                 :deploy,
                 %{remote_operation: 123, remote_trust_level: 456},
                 profile
               )
    end

    test "no remote context is allowed" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          remote_trust: :local
        })

      assert :allowed = Evaluator.check(:read, %{}, profile)
    end
  end

  # --- SECURITY: Repair strategy fail-closed ---

  describe "repair strategy fail-closed" do
    test "non-atom repair strategy denied" do
      profile = Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :unrestricted})

      assert {:denied, :invalid_repair_strategy} =
               Evaluator.check(:read, %{repair_strategy: "retry"}, profile)
    end

    test "nil repair strategy denied" do
      profile = Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :unrestricted})

      assert {:denied, :invalid_repair_strategy} =
               Evaluator.check(:read, %{repair_strategy: nil}, profile)
    end

    test "no repair strategy is allowed" do
      profile = Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :unrestricted})

      assert :allowed = Evaluator.check(:read, %{}, profile)
    end
  end

  # --- SECURITY: no_network blocks MCP network and remote ---

  describe "no_network sandbox blocks network-adjacent operations" do
    test "no_network denies connect action" do
      profile = Profile.new!(%{sandbox_profile: :no_network})

      assert {:denied, :sandbox_no_network} = Evaluator.check_sandbox(:connect, %{}, profile)
    end

    test "no_network denies download action" do
      profile = Profile.new!(%{sandbox_profile: :no_network})

      assert {:denied, :sandbox_no_network} = Evaluator.check_sandbox(:download, %{}, profile)
    end

    test "no_network denies upload action" do
      profile = Profile.new!(%{sandbox_profile: :no_network})

      assert {:denied, :sandbox_no_network} = Evaluator.check_sandbox(:upload, %{}, profile)
    end

    test "no_network denies MCP network category" do
      profile = Profile.new!(%{sandbox_profile: :no_network})

      assert {:denied, :sandbox_no_network} =
               Evaluator.check_sandbox(:execute, %{mcp_category: :network}, profile)
    end

    test "no_network denies remote operations" do
      profile = Profile.new!(%{sandbox_profile: :no_network})

      assert {:denied, :sandbox_no_network} =
               Evaluator.check_sandbox(:execute, %{remote_operation: :read_status}, profile)
    end
  end

  # --- SECURITY: read_only blocks expanded mutation list ---

  describe "read_only blocks expanded mutation operations" do
    setup do
      %{profile: Profile.new!(%{sandbox_profile: :read_only})}
    end

    test "denies :save action", %{profile: profile} do
      assert {:denied, :sandbox_read_only} =
               Evaluator.check_sandbox(
                 :save,
                 %{path: "/workspace/f.ex", workspace_root: "/workspace"},
                 profile
               )
    end

    test "denies :update action", %{profile: profile} do
      assert {:denied, :sandbox_read_only} =
               Evaluator.check_sandbox(
                 :update,
                 %{path: "/workspace/f.ex", workspace_root: "/workspace"},
                 profile
               )
    end

    test "denies :remove action", %{profile: profile} do
      assert {:denied, :sandbox_read_only} =
               Evaluator.check_sandbox(
                 :remove,
                 %{path: "/workspace/f.ex", workspace_root: "/workspace"},
                 profile
               )
    end

    test "denies :insert action", %{profile: profile} do
      assert {:denied, :sandbox_read_only} =
               Evaluator.check_sandbox(
                 :insert,
                 %{path: "/workspace/f.ex", workspace_root: "/workspace"},
                 profile
               )
    end

    test "denies :rename action", %{profile: profile} do
      assert {:denied, :sandbox_read_only} =
               Evaluator.check_sandbox(
                 :rename,
                 %{path: "/workspace/f.ex", workspace_root: "/workspace"},
                 profile
               )
    end

    test "denies :move action", %{profile: profile} do
      assert {:denied, :sandbox_read_only} =
               Evaluator.check_sandbox(
                 :move,
                 %{path: "/workspace/f.ex", workspace_root: "/workspace"},
                 profile
               )
    end

    test "denies :copy action", %{profile: profile} do
      assert {:denied, :sandbox_read_only} =
               Evaluator.check_sandbox(
                 :copy,
                 %{path: "/workspace/f.ex", workspace_root: "/workspace"},
                 profile
               )
    end

    test "denies mutation MCP category :write", %{profile: profile} do
      assert {:denied, :sandbox_read_only} =
               Evaluator.check_sandbox(
                 :read,
                 %{path: "/workspace/f.ex", workspace_root: "/workspace", mcp_category: :write},
                 profile
               )
    end

    test "denies mutation MCP category :shell", %{profile: profile} do
      assert {:denied, :sandbox_read_only} =
               Evaluator.check_sandbox(
                 :read,
                 %{path: "/workspace/f.ex", workspace_root: "/workspace", mcp_category: :shell},
                 profile
               )
    end

    test "denies :execute action", %{profile: profile} do
      assert {:denied, :sandbox_read_only} =
               Evaluator.check_sandbox(
                 :execute,
                 %{path: "/workspace/f.ex", workspace_root: "/workspace"},
                 profile
               )
    end

    test "denies :shell action", %{profile: profile} do
      assert {:denied, :sandbox_read_only} =
               Evaluator.check_sandbox(
                 :shell,
                 %{path: "/workspace/f.ex", workspace_root: "/workspace"},
                 profile
               )
    end

    test "denies :run action", %{profile: profile} do
      assert {:denied, :sandbox_read_only} =
               Evaluator.check_sandbox(
                 :run,
                 %{path: "/workspace/f.ex", workspace_root: "/workspace"},
                 profile
               )
    end

    test "allows read MCP category", %{profile: profile} do
      assert :allowed =
               Evaluator.check_sandbox(
                 :read,
                 %{path: "/workspace/f.ex", workspace_root: "/workspace", mcp_category: :read},
                 profile
               )
    end
  end

  # --- SECURITY: Glob matching ---

  describe "glob matching security" do
    test "question mark does not match forward slash" do
      refute Evaluator.denied_by_glob?("/a/b", ["/a?b"])
    end

    test "question mark matches non-slash char" do
      assert Evaluator.denied_by_glob?("/axb", ["/a?b"])
    end

    test "regex metacharacters in path are escaped" do
      # . in glob is literal, not regex wildcard
      refute Evaluator.denied_by_glob?("/etc/fileXex", ["/etc/file.ex"])
      assert Evaluator.denied_by_glob?("/etc/file.ex", ["/etc/file.ex"])
    end

    test "regex plus sign is literal" do
      assert Evaluator.denied_by_glob?("/a+b", ["/a+b"])
      refute Evaluator.denied_by_glob?("/aXb", ["/a+b"])
    end

    test "regex braces are literal" do
      assert Evaluator.denied_by_glob?("/a{b}", ["/a{b}"])
    end

    test "double star matches everything" do
      assert Evaluator.denied_by_glob?("/anything/at/all", ["**"])
    end

    test "double star between slashes matches zero segments" do
      assert Evaluator.denied_by_glob?("/a/b", ["/a/**/b"])
    end

    test "double star between slashes matches multiple segments" do
      assert Evaluator.denied_by_glob?("/a/x/y/b", ["/a/**/b"])
    end

    test "glob at start matches paths with leading slash" do
      assert Evaluator.denied_by_glob?("/secret/key.pem", ["**/secret/**"])
    end

    test "literal bracket in glob pattern is handled safely" do
      # Regex.escape prevents [ from being interpreted as regex char class
      assert Evaluator.denied_by_glob?("[", ["["])
      refute Evaluator.denied_by_glob?("/anything", ["["])
    end
  end

  # --- SECURITY: effective_path (sandbox_path takes precedence) ---

  describe "effective_path: sandbox_path takes precedence over path" do
    test "deny globs use effective_path (sandbox_path)" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          deny_globs: ["/secret/**"]
        })

      # sandbox_path is /secret/key.pem — should be denied
      assert {:denied, :denied_by_glob} =
               Evaluator.check(
                 :read,
                 %{sandbox_path: "/secret/key.pem", path: "/workspace/safe.ex"},
                 profile
               )
    end

    test "allow paths use effective_path (sandbox_path)" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          allow_paths: ["/workspace/**"]
        })

      # sandbox_path is in allowed paths
      assert :allowed =
               Evaluator.check(
                 :read,
                 %{sandbox_path: "/workspace/file.ex", path: "/etc/passwd"},
                 profile
               )
    end

    test "workspace_only uses effective_path (sandbox_path)" do
      profile = Profile.new!(%{sandbox_profile: :workspace_only})

      assert {:denied, :sandbox_workspace_only} =
               Evaluator.check_sandbox(
                 :read,
                 %{
                   sandbox_path: "/etc/passwd",
                   path: "/workspace/safe.ex",
                   workspace_root: "/workspace"
                 },
                 profile
               )
    end
  end

  # --- SECURITY: Stricter approval from dimensions ---

  describe "stricter approval from dimensions" do
    test "repair approval_required is stricter than suggest_approve mode" do
      profile = Profile.new!(%{approval_mode: :suggest_approve, sandbox_profile: :unrestricted})

      # suggest_approve mode returns {:needs_approval, :suggest_approve}
      # but repair returns {:needs_approval, {:repair_approval_required, ...}}
      # which is stricter and should win
      assert {:needs_approval, {:repair_approval_required, _}} =
               Evaluator.check(:read, %{repair_strategy: :patch}, profile)
    end

    test "mcp trust exceeded is stricter than suggest_approve" do
      profile =
        Profile.new!(%{
          approval_mode: :suggest_approve,
          sandbox_profile: :unrestricted,
          mcp_trust: :read
        })

      # mcp dimension returns stricter needs_approval than suggest_approve
      assert {:needs_approval, {:mcp_trust_exceeded, _}} =
               Evaluator.check(:execute, %{mcp_category: :shell}, profile)
    end
  end

  # --- SECURITY: String action normalization (fail-closed) ---

  describe "string action normalization" do
    test "known string action is normalized to atom" do
      profile =
        Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :read_only})

      # "write" normalizes to :write → sandbox_read_only deny
      assert {:denied, :sandbox_read_only} =
               Evaluator.check(
                 "write",
                 %{path: "/workspace/f.ex", workspace_root: "/workspace"},
                 profile
               )
    end

    test "unknown string action treated as dangerous (fail-closed)" do
      profile =
        Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :read_only})

      # "obliterate" is not a known action → :unknown → globally denied
      assert {:denied, :unknown_action} =
               Evaluator.check(
                 "obliterate",
                 %{path: "/workspace/f.ex", workspace_root: "/workspace"},
                 profile
               )
    end

    test "known string action read is allowed in read_only sandbox" do
      profile =
        Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :read_only})

      assert :allowed =
               Evaluator.check(
                 "read",
                 %{path: "/workspace/f.ex", workspace_root: "/workspace"},
                 profile
               )
    end

    test "normalize_action returns atom for known atom input" do
      assert Evaluator.normalize_action(:read) == :read
      assert Evaluator.normalize_action(:write) == :write
    end

    test "normalize_action returns unknown for unknown atom" do
      assert Evaluator.normalize_action(:obliterate) == :unknown
      assert Evaluator.normalize_action(nil) == :unknown
      assert Evaluator.normalize_action(true) == :unknown
    end

    test "normalize_action converts known string to atom" do
      assert Evaluator.normalize_action("read") == :read
      assert Evaluator.normalize_action("write") == :write
    end

    test "normalize_action returns unknown for unknown string" do
      assert Evaluator.normalize_action("obliterate") == :unknown
    end

    test "normalize_action returns unknown for non-string non-atom" do
      assert Evaluator.normalize_action(123) == :unknown
    end

    test "network string action denied under no_network" do
      profile = Profile.new!(%{sandbox_profile: :no_network})

      assert {:denied, :sandbox_no_network} =
               Evaluator.check_sandbox("network", %{}, profile)
    end
  end

  # --- SECURITY: Unknown atom action fail-closed ---

  describe "unknown atom action fail-closed" do
    test "unknown atom action is globally denied" do
      profile =
        Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :unrestricted})

      assert {:denied, :unknown_action} =
               Evaluator.check(:obliterate, %{path: "/workspace/f.ex"}, profile)
    end

    test "unknown atom action denied even with auto_approve" do
      profile =
        Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :unrestricted})

      assert {:denied, :unknown_action} = Evaluator.check(:teleport, %{}, profile)
    end
  end

  # --- SECURITY: Repair without strategy (fail-closed) ---

  describe "repair without strategy fail-closed" do
    test "repair action without repair_strategy is denied" do
      profile =
        Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :unrestricted})

      assert {:denied, :missing_repair_strategy} =
               Evaluator.check(:repair, %{}, profile)
    end

    test "repair string action without repair_strategy is denied" do
      profile =
        Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :unrestricted})

      assert {:denied, :missing_repair_strategy} =
               Evaluator.check("repair", %{}, profile)
    end

    test "repair action with valid strategy checks normally" do
      profile =
        Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :unrestricted})

      assert :allowed = Evaluator.check(:repair, %{repair_strategy: :retry}, profile)
    end

    test "non-repair action without repair_strategy is allowed" do
      profile =
        Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :unrestricted})

      assert :allowed = Evaluator.check(:read, %{}, profile)
    end
  end

  # --- SECURITY: Canonicalized path glob matching ---

  describe "canonicalized path glob matching" do
    test "denied_by_glob canonicalises .. before matching" do
      # /workspace/../etc/passwd → /etc/passwd → matches /etc/**
      assert Evaluator.denied_by_glob?("/workspace/../etc/passwd", ["/etc/**"])
    end

    test "allowed_by_path canonicalises .. before matching" do
      # /workspace/sub/../file.ex → /workspace/file.ex → matches /workspace/**
      assert Evaluator.allowed_by_path?("/workspace/sub/../file.ex", ["/workspace/**"])
    end

    test "allowed_by_path does not match traversal escaping workspace" do
      # /workspace/../etc/passwd → /etc/passwd → does NOT match /workspace/**
      refute Evaluator.allowed_by_path?("/workspace/../etc/passwd", ["/workspace/**"])
    end

    test "allowed_by_path preserves leading .. in relative paths" do
      # ../secrets/key stays as ../secrets/key, NOT secrets/key
      refute Evaluator.allowed_by_path?("../secrets/key", ["secrets/**"])
    end

    test "allowed_by_path preserves multiple leading .. in relative paths" do
      # a/../../secrets/key resolves .. against "a" then preserves the next ..
      refute Evaluator.allowed_by_path?("a/../../secrets/key", ["secrets/**"])
    end

    test "deny glob catches absolute path traversal above root" do
      assert Evaluator.denied_by_glob?("/../etc/passwd", ["/etc/**"])
    end

    test "deny glob catches absolute over-traversal with multiple .." do
      assert Evaluator.denied_by_glob?("/workspace/../../etc/passwd", ["/etc/**"])
      assert Evaluator.denied_by_glob?("/a/b/../../../etc/passwd", ["/etc/**"])
    end

    test "check denies absolute over-traversal despite wildcard allow" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          deny_globs: ["/etc/**"],
          allow_paths: ["**"]
        })

      assert {:denied, :denied_by_glob} =
               Evaluator.check(:read, %{path: "/workspace/../../etc/passwd"}, profile)
    end

    test "relative leading .. remains preserved and does not match allow path" do
      refute Evaluator.allowed_by_path?("../secrets/key", ["secrets/**"])
      refute Evaluator.allowed_by_path?("a/../../secrets/key", ["secrets/**"])
    end
  end
end
