defmodule Tet.Security.ComplianceSuite do
  @moduledoc """
  Security compliance test suite — BD-0070.

  Runs a battery of compliance checks against the security modules to
  verify fail-closed behavior across every attack dimension. Each check
  returns `{:ok, details}` on pass or `{:error, failures}` on failure.

  ## Compliance checks

    1. **Path traversal prevention** — `../`, encoding attacks, null bytes blocked.
    2. **Sandbox boundary enforcement** — workspace-only constraints hold.
    3. **Shell command injection prevention** — unknown/dangerous commands denied.
    4. **Secret redaction completeness** — all known secret patterns are caught.
    5. **MCP trust boundary validation** — classification and permission gates work.
    6. **Remote credential scoping** — trust boundaries and env policies hold.
    7. **Redacted-region patch rejection** — patches touching secrets are gated.

  Pure functions, no processes, no side effects.

  ## Architecture

  Check implementations are split by domain:

    - `ComplianceSuite.Checks.FileSystem` — path traversal, sandbox boundary
    - `ComplianceSuite.Checks.DataProtection` — secret redaction, redacted-region patch
    - `ComplianceSuite.Checks.TrustBoundary` — shell injection, MCP trust, remote credential
    - `ComplianceSuite.Checks.Helpers` — shared assertion/result helpers

  This module provides the public API, report generation, and type definitions.
  """

  alias Tet.Security.ComplianceSuite.Checks.FileSystem
  alias Tet.Security.ComplianceSuite.Checks.DataProtection
  alias Tet.Security.ComplianceSuite.Checks.TrustBoundary

  @type check_name :: atom()
  @type check_result :: {:ok, map()} | {:error, map()}
  @type check_spec :: %{name: check_name(), description: String.t(), run: (-> check_result())}

  # --- Public API ---

  @doc "Returns all compliance check specifications."
  @spec checks() :: [check_spec()]
  def checks do
    [
      %{
        name: :path_traversal_prevention,
        description:
          "Verifies path traversal attacks (../, encoding tricks, null bytes) are blocked",
        run: &FileSystem.check_path_traversal/0
      },
      %{
        name: :sandbox_boundary_enforcement,
        description:
          "Verifies sandbox profiles correctly constrain filesystem and network access",
        run: &FileSystem.check_sandbox_boundary/0
      },
      %{
        name: :shell_command_injection_prevention,
        description: "Verifies shell policy blocks unknown executables and dangerous commands",
        run: &TrustBoundary.check_shell_injection/0
      },
      %{
        name: :secret_redaction_completeness,
        description: "Verifies all known secret patterns are detected and redacted",
        run: &DataProtection.check_secret_redaction/0
      },
      %{
        name: :mcp_trust_boundary_validation,
        description: "Verifies MCP classification and permission gates enforce trust boundaries",
        run: &TrustBoundary.check_mcp_trust/0
      },
      %{
        name: :remote_credential_scoping,
        description:
          "Verifies remote trust boundaries and env policies prevent credential leakage",
        run: &TrustBoundary.check_remote_credential_scoping/0
      },
      %{
        name: :redacted_region_patch_rejection,
        description:
          "Verifies patches involving secrets require approval and are not auto-applied",
        run: &DataProtection.check_redacted_region_patch/0
      }
    ]
  end

  @doc "Runs all compliance checks and returns results."
  @spec run_all() :: %{check_name() => check_result()}
  def run_all do
    checks()
    |> Enum.map(fn %{name: name, run: run_fn} ->
      {name, run_fn.()}
    end)
    |> Map.new()
  end

  @doc "Runs a specific compliance check by name."
  @spec run(check_name()) :: check_result() | {:error, :unknown_check}
  def run(name) when is_atom(name) do
    case Enum.find(checks(), &(&1.name == name)) do
      %{run: run_fn} -> run_fn.()
      nil -> {:error, :unknown_check}
    end
  end

  @doc "Generates a compliance report from results."
  @spec report(%{check_name() => check_result()}) :: map()
  def report(results) when is_map(results) do
    total = map_size(results)
    passed = count_passed(results)
    failed = total - passed

    %{
      total: total,
      passed: passed,
      failed: failed,
      compliant: failed == 0,
      checks:
        Map.new(results, fn {name, result} ->
          {name, format_result(result)}
        end)
    }
  end

  # --- Private helpers ---

  defp count_passed(results) do
    Enum.count(results, fn
      {_, {:ok, _}} -> true
      _ -> false
    end)
  end

  defp format_result({:ok, meta}), do: %{status: :passed, details: meta}
  defp format_result({:error, meta}), do: %{status: :failed, details: meta}
end
