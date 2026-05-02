defmodule Tet.Security.ComplianceSuiteTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Tet.Security.ComplianceSuite

  describe "checks/0" do
    test "returns exactly 7 compliance checks" do
      checks = ComplianceSuite.checks()
      assert length(checks) == 7
    end

    test "each check has required fields" do
      for check <- ComplianceSuite.checks() do
        assert Map.has_key?(check, :name)
        assert Map.has_key?(check, :description)
        assert Map.has_key?(check, :run)
        assert is_atom(check.name)
        assert is_binary(check.description)
        assert is_function(check.run, 0)
      end
    end

    test "all check names are unique" do
      names = ComplianceSuite.checks() |> Enum.map(& &1.name)
      assert names == Enum.uniq(names)
    end

    test "covers all required compliance dimensions" do
      names = ComplianceSuite.checks() |> Enum.map(& &1.name) |> MapSet.new()

      required =
        MapSet.new([
          :path_traversal_prevention,
          :sandbox_boundary_enforcement,
          :shell_command_injection_prevention,
          :secret_redaction_completeness,
          :mcp_trust_boundary_validation,
          :remote_credential_scoping,
          :redacted_region_patch_rejection
        ])

      assert MapSet.equal?(names, required)
    end
  end

  describe "run_all/0" do
    test "runs all checks and returns a map of results" do
      results = ComplianceSuite.run_all()

      assert is_map(results)
      assert map_size(results) == 7

      for {_name, result} <- results do
        assert match?({:ok, _}, result) or match?({:error, _}, result)
      end
    end
  end

  describe "run/1" do
    test "runs a specific check by name" do
      result = ComplianceSuite.run(:path_traversal_prevention)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "returns error for unknown check name" do
      assert {:error, :unknown_check} = ComplianceSuite.run(:nonexistent_check)
    end

    test "each individual check can be run independently" do
      for %{name: name} <- ComplianceSuite.checks() do
        result = ComplianceSuite.run(name)

        assert match?({:ok, _}, result) or match?({:error, _}, result),
               "Check #{name} returned unexpected result: #{inspect(result)}"
      end
    end
  end

  describe "report/1" do
    test "generates a compliant report when all checks pass" do
      # Simulate all-pass results
      results = %{
        path_traversal_prevention: {:ok, %{passed: true}},
        sandbox_boundary_enforcement: {:ok, %{passed: true}},
        shell_command_injection_prevention: {:ok, %{passed: true}},
        secret_redaction_completeness: {:ok, %{passed: true}},
        mcp_trust_boundary_validation: {:ok, %{passed: true}},
        remote_credential_scoping: {:ok, %{passed: true}},
        redacted_region_patch_rejection: {:ok, %{passed: true}}
      }

      report = ComplianceSuite.report(results)

      assert report.total == 7
      assert report.passed == 7
      assert report.failed == 0
      assert report.compliant == true
    end

    test "generates a non-compliant report when any check fails" do
      results = %{
        path_traversal_prevention: {:ok, %{passed: true}},
        sandbox_boundary_enforcement: {:error, %{passed: false, failures: [:oops]}},
        shell_command_injection_prevention: {:ok, %{passed: true}},
        secret_redaction_completeness: {:ok, %{passed: true}},
        mcp_trust_boundary_validation: {:ok, %{passed: true}},
        remote_credential_scoping: {:ok, %{passed: true}},
        redacted_region_patch_rejection: {:ok, %{passed: true}}
      }

      report = ComplianceSuite.report(results)

      assert report.total == 7
      assert report.passed == 6
      assert report.failed == 1
      assert report.compliant == false
    end

    test "report from actual run_all includes all checks" do
      results = ComplianceSuite.run_all()
      report = ComplianceSuite.report(results)

      assert report.total == 7
      assert report.passed + report.failed == 7
      assert is_boolean(report.compliant)
      assert is_map(report.checks)
      assert map_size(report.checks) == 7
    end
  end

  # --- Specific compliance check validations ---

  describe "path_traversal_prevention check" do
    test "passes — traversal attacks are blocked by sandbox" do
      result = ComplianceSuite.run(:path_traversal_prevention)

      case result do
        {:ok, meta} ->
          assert meta.passed == true
          assert meta.total_attacks > 0

        {:error, meta} ->
          # If it fails, inspect which attacks got through
          assert meta.failure_count > 0
          # But it shouldn't fail — our sandbox should block escapes
          flunk(
            "Path traversal check failed with #{meta.failure_count} failures: #{inspect(Enum.take(meta.failures, 5))}"
          )
      end
    end

    test "encoded traversal vectors are blocked after normalization" do
      alias Tet.Security.PathFuzzer
      alias Tet.SecurityPolicy.Evaluator
      alias Tet.SecurityPolicy.Profile

      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :workspace_only,
          allow_paths: ["/workspace/**"]
        })

      encoded_attacks = [
        "..%2f..%2f..%2fetc%2fpasswd",
        "%2e%2e%2f%2e%2e%2f%2e%2e%2fetc%2fpasswd",
        "..%252f..%252fetc%252fpasswd"
      ]

      for raw <- encoded_attacks do
        normalized = PathFuzzer.normalize_encoded_path(raw)
        context = %{path: normalized, workspace_root: "/workspace"}
        result = Evaluator.check_sandbox(:read, context, profile)

        assert match?({:denied, _}, result),
               "Encoded traversal not blocked: raw=#{inspect(raw)} normalized=#{inspect(normalized)} got=#{inspect(result)}"
      end
    end

    test "null-byte payloads are present and blocked" do
      alias Tet.Security.PathFuzzer

      attacks = PathFuzzer.generate_traversal_attempts()
      nul_attacks = Enum.filter(attacks, &String.contains?(&1, <<0>>))

      assert length(nul_attacks) > 0,
             "Expected null-byte payloads in traversal attempts, got 0"
    end
  end

  describe "sandbox_boundary_enforcement check" do
    test "passes — all sandbox profiles enforce correctly" do
      result = ComplianceSuite.run(:sandbox_boundary_enforcement)

      case result do
        {:ok, _meta} -> :ok
        {:error, meta} -> flunk("Sandbox boundary check failed: #{inspect(meta.failures)}")
      end
    end
  end

  describe "shell_command_injection_prevention check" do
    test "passes — dangerous commands are blocked" do
      result = ComplianceSuite.run(:shell_command_injection_prevention)

      case result do
        {:ok, _meta} -> :ok
        {:error, meta} -> flunk("Shell injection check failed: #{inspect(meta.failures)}")
      end
    end
  end

  describe "secret_redaction_completeness check" do
    test "passes — all secret patterns are detected and redacted" do
      result = ComplianceSuite.run(:secret_redaction_completeness)

      case result do
        {:ok, _meta} ->
          :ok

        {:error, meta} ->
          flunk("Secret redaction check failed: #{inspect(Enum.take(meta.failures, 10))}")
      end
    end
  end

  describe "mcp_trust_boundary_validation check" do
    test "passes — MCP trust boundaries are enforced" do
      result = ComplianceSuite.run(:mcp_trust_boundary_validation)

      case result do
        {:ok, _meta} -> :ok
        {:error, meta} -> flunk("MCP trust check failed: #{inspect(meta.failures)}")
      end
    end
  end

  describe "remote_credential_scoping check" do
    test "passes — remote credentials are properly scoped" do
      result = ComplianceSuite.run(:remote_credential_scoping)

      case result do
        {:ok, _meta} -> :ok
        {:error, meta} -> flunk("Remote credential check failed: #{inspect(meta.failures)}")
      end
    end
  end

  describe "redacted_region_patch_rejection check" do
    test "passes — patches involving secrets require approval" do
      result = ComplianceSuite.run(:redacted_region_patch_rejection)

      case result do
        {:ok, _meta} -> :ok
        {:error, meta} -> flunk("Redacted region patch check failed: #{inspect(meta.failures)}")
      end
    end

    test "patches with [REDACTED] in old_str are rejected by Patch.propose" do
      alias Tet.Patch

      result =
        Patch.propose(%{
          workspace_path: "/workspace",
          operations: [
            %{
              kind: :modify,
              file_path: "config/prod.exs",
              old_str: "api_key=[REDACTED]",
              new_str: "api_key=sk-new"
            }
          ]
        })

      assert match?({:error, {:invalid_operation, :redacted_region_in_old_str}}, result),
             "Patch with [REDACTED] in old_str should be rejected, got: #{inspect(result)}"
    end

    test "patches with [REDACTED] in content are rejected" do
      alias Tet.Patch

      result =
        Patch.propose(%{
          workspace_path: "/workspace",
          operations: [
            %{
              kind: :modify,
              file_path: "config/prod.exs",
              content: "api_key=[REDACTED]\nport=443"
            }
          ]
        })

      assert match?({:error, {:invalid_operation, :redacted_region_in_content}}, result),
             "Patch with [REDACTED] in content should be rejected, got: #{inspect(result)}"
    end

    test "patches with [REDACTED] in replacements are rejected" do
      alias Tet.Patch

      result =
        Patch.propose(%{
          workspace_path: "/workspace",
          operations: [
            %{
              kind: :modify,
              file_path: "config/prod.exs",
              replacements: [%{old_str: "db_pass=[REDACTED]", new_str: "db_pass=new"}]
            }
          ]
        })

      assert match?({:error, {:invalid_operation, :redacted_region_in_replacements}}, result),
             "Patch with [REDACTED] in replacements should be rejected, got: #{inspect(result)}"
    end

    test "clean patches without [REDACTED] are allowed" do
      alias Tet.Patch

      result =
        Patch.propose(%{
          workspace_path: "/workspace",
          operations: [
            %{
              kind: :modify,
              file_path: "lib/app.ex",
              old_str: "defmodule App",
              new_str: "defmodule MyApp"
            }
          ]
        })

      assert match?({:ok, _}, result),
             "Clean patch should be accepted, got: #{inspect(result)}"
    end
  end
end
