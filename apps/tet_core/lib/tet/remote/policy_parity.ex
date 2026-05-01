defmodule Tet.Remote.PolicyParity do
  @moduledoc """
  Policy parity contract for remote tool execution — BD-0056.

  Remote tools must pass the same checks as local tools for task category
  gates, approval requirements, sandbox restrictions, and shell policies.
  No special treatment. No secret shortcuts. Remote is *less* trusted,
  not *differently* trusted.

  ## Parity contract

  The parity contract ensures:

    1. **Active task** — remote tools need an active task, just like local.
    2. **Category gates** — task category must permit the operation type.
    3. **Approval flow** — same approval gates as local equivalents.
    4. **Sandbox restrictions** — cwd must be within workspace root.
    5. **Shell policy** — dangerous commands are blocked regardless of
       execution site.
    6. **Env policy** — env variable forwarding is filtered by the same rules.
    7. **Trust boundary** — trust level restricts available operations,
       never widens them.

  ## Design principle

  Remote policy parity means: for every policy gate, the remote execution
  path hits the *same* gate with the *same* inputs. No bypasses. If a
  local tool needs `:acting` category, so does the remote equivalent.
  If a local shell blocks `rm -rf /`, so does the remote shell.

  This module is pure data and pure functions. It does not dispatch tools,
  touch the filesystem, shell out, persist events, or ask a terminal question.
  """

  alias Tet.PlanMode.{Gate, Policy}
  alias Tet.Remote.{EnvPolicy, TrustBoundary}
  alias Tet.ShellPolicy
  alias Tet.Tool.Contract

  @type trust_level :: TrustBoundary.trust_level()
  @type operation :: TrustBoundary.operation()

  @type remote_context :: %{
          required(:trust_level) => trust_level(),
          required(:task_id) => binary() | nil,
          required(:task_category) => atom() | nil,
          required(:mode) => atom(),
          optional(:command) => [String.t()],
          optional(:env_allowlist) => [binary()],
          optional(:env_map) => map(),
          optional(:contract) => Contract.t(),
          optional(:approval_status) => :approved | :pending | :rejected | :unknown,
          optional(:cwd) => binary(),
          optional(:workspace_root) => binary(),
          optional(:operation) => atom()
        }

  @type parity_error ::
          {:parity_violation, {:no_active_task, map()}}
          | {:parity_violation, {:category_gate_blocked, atom()}}
          | {:parity_violation, {:trust_boundary_denied, term()}}
          | {:parity_violation, {:shell_command_blocked, term()}}
          | {:parity_violation, {:env_policy_denied, term()}}
          | {:parity_violation, {:approval_required_for_mutation, map()}}
          | {:parity_violation, {:sandbox_violation, term()}}

  @type parity_result :: :ok | {:error, parity_error()}

  @doc """
  Checks whether a remote tool execution passes all policy parity gates.

  Returns `:ok` if the remote execution would pass the same gates as a local
  execution. Returns `{:error, {:parity_violation, reason}}` otherwise.

  This function is the single entry point for policy parity verification.
  It delegates to individual gate checks but ensures *all* gates are
  evaluated in the correct order, mirroring the local execution path.

  ## Example

      iex> Tet.Remote.PolicyParity.check(%{
      ...>   trust_level: :trusted_remote,
      ...>   task_id: "t1",
      ...>   task_category: :acting,
      ...>   mode: :execute,
      ...>   contract: Tet.ShellPolicy.shell_contract(),
      ...>   approval_status: :approved
      ...> })
      :ok
  """
  @spec check(remote_context()) :: parity_result()
  def check(context) when is_map(context) do
    with :ok <- check_active_task(context),
         :ok <- check_category_gate(context),
         :ok <- check_trust_boundary(context),
         :ok <- check_shell_policy(context),
         :ok <- check_env_policy(context),
         :ok <- check_approval_parity(context),
         :ok <- check_sandbox_parity(context) do
      :ok
    end
  end

  @doc """
  Checks that remote execution requires an active task — same as local.

  Local tools are gated by `Tet.PlanMode.Gate`, which blocks when
  `require_active_task` is true and no valid task_id/category is present.
  Remote execution must hit the same gate: no task, no execution.
  """
  @spec check_active_task(remote_context()) :: parity_result()
  def check_active_task(context) when is_map(context) do
    policy = Policy.default()
    task_id = Map.get(context, :task_id)
    task_category = Map.get(context, :task_category)

    if policy.require_active_task do
      cond do
        not valid_task_id?(task_id) ->
          {:error, {:parity_violation, {:no_active_task, %{task_id: task_id}}}}

        not valid_task_category?(task_category) ->
          {:error, {:parity_violation, {:no_active_task, %{task_category: task_category}}}}

        true ->
          :ok
      end
    else
      :ok
    end
  end

  @doc """
  Checks that the remote execution passes the same category gate as local.

  A remote tool in plan mode with a researching task cannot mutate — same
  as local. An `:acting` category unlocks execution — same as local.
  The trust level never widens category permissions.

  When no contract is supplied but a command is present, the shell contract
  is used as the default — this ensures mode gating applies even for
  bare command execution (e.g., `mode: :plan` + command is blocked).
  """
  @spec check_category_gate(remote_context()) :: parity_result()
  def check_category_gate(context) when is_map(context) do
    contract = Map.get(context, :contract)
    command = Map.get(context, :command)
    operation = Map.get(context, :operation)
    policy = Policy.default()

    # Security: mutating signals ALWAYS override the supplied contract
    # (BD-0056 #1, #4). Shell commands use the shell contract regardless
    # of any supplied contract. Mutating operations also use the shell
    # contract even when a read-only contract is attached — otherwise a
    # caller could bypass mode gating by pairing a read-only contract
    # with :write_scoped_files (BD-0056 #4).
    effective_contract =
      cond do
        shell_command?(command) ->
          ShellPolicy.shell_contract()

        mutating_operation?(operation) ->
          ShellPolicy.shell_contract()

        match?(%Contract{}, contract) ->
          contract

        true ->
          nil
      end

    case effective_contract do
      %Contract{} = c ->
        gate_context = build_gate_context(context)

        case Gate.evaluate(c, policy, gate_context) do
          :allow ->
            :ok

          {:guide, _message} ->
            :ok

          {:block, reason} ->
            {:error, {:parity_violation, {:category_gate_blocked, reason}}}
        end

      nil ->
        # No contract, no command, no mutating operation: fall back to
        # category check. Only non-mutating, non-shell requests reach here.
        category = Map.get(context, :task_category)

        if ShellPolicy.acting_category?(category) do
          :ok
        else
          {:error, {:parity_violation, {:category_gate_blocked, :no_acting_category}}}
        end
    end
  end

  @doc """
  Checks that the trust boundary permits the requested operation.

  Remote execution is always constrained by trust level. An untrusted
  remote cannot execute commands. A trusted remote cannot install packages.
  This is *additional* to the local gates — trust never widens, only narrows.

  If the context includes an explicit `:operation` field, that operation is
  checked directly against the trust boundary. Otherwise, the operation is
  inferred from the contract and command.
  """
  @spec check_trust_boundary(remote_context()) :: parity_result()
  def check_trust_boundary(context) when is_map(context) do
    trust_level = Map.get(context, :trust_level)

    operation =
      case Map.get(context, :operation) do
        nil -> infer_operation(context)
        explicit_op -> explicit_op
      end

    with {:ok, _} <- TrustBoundary.minimum_trust_for(operation),
         :ok <- TrustBoundary.check_operation(trust_level, operation) do
      :ok
    else
      {:error, reason} ->
        {:error, {:parity_violation, {:trust_boundary_denied, reason}}}
    end
  end

  @doc """
  Checks that shell commands pass the same allowlist as local execution.

  A remote `rm -rf /` is just as blocked as a local `rm -rf /`. The shell
  policy allowlist applies identically regardless of execution site.
  """
  @spec check_shell_policy(remote_context()) :: parity_result()
  def check_shell_policy(context) when is_map(context) do
    case Map.get(context, :command) do
      nil ->
        :ok

      command when is_list(command) ->
        case ShellPolicy.check_command(command) do
          {:ok, _risk} ->
            :ok

          {:error, reason} ->
            {:error, {:parity_violation, {:shell_command_blocked, reason}}}
        end

      _ ->
        {:error, {:parity_violation, {:shell_command_blocked, :invalid_command_vector}}}
    end
  end

  @doc """
  Checks that env variable forwarding passes the same filters as local.

  Remote execution must use the same default-deny allowlist and secret
  redaction as local. The env policy does not loosen just because the
  execution target is elsewhere.

  If `env_map` is present but `env_allowlist` is nil, the check fails
  closed — no env forwarding without an explicit allowlist.
  If `env_map` contains keys outside the allowlist, the check rejects.
  """
  @spec check_env_policy(remote_context()) :: parity_result()
  def check_env_policy(context) when is_map(context) do
    allowlist = Map.get(context, :env_allowlist)
    env_map = Map.get(context, :env_map)

    case {allowlist, env_map} do
      {nil, env_map} when is_map(env_map) and map_size(env_map) > 0 ->
        # Fail closed: env_map present but no allowlist to filter it.
        {:error, {:parity_violation, {:env_policy_denied, :env_map_without_allowlist}}}

      {nil, _} ->
        # No env_map, no allowlist — nothing to check.
        :ok

      {allowlist, nil} when is_list(allowlist) ->
        validate_allowlist_only(allowlist)

      {allowlist, env_map} when is_list(allowlist) and is_map(env_map) ->
        with :ok <- validate_allowlist_only(allowlist),
             :ok <- check_env_map_keys(env_map, allowlist) do
          :ok
        end

      _ ->
        {:error, {:parity_violation, {:env_policy_denied, :invalid_allowlist}}}
    end
  end

  @doc """
  Checks that remote mutating tools require the same approval as local.

  Mutating tools (write_files, install_packages, etc.) require approval
  regardless of execution site. Remote does not skip the approval queue.

  The `approval_status` field in context must be `:approved` for any
  mutating operation. All other statuses (`:pending`, `:rejected`,
  `:unknown`) result in a parity violation.
  """
  @spec check_approval_parity(remote_context()) :: parity_result()
  def check_approval_parity(context) when is_map(context) do
    contract = Map.get(context, :contract)
    command = Map.get(context, :command)
    operation = Map.get(context, :operation)
    approval_status = Map.get(context, :approval_status)

    # Security: compute approval need from ALL signals combined (BD-0056 #2).
    # A read-only contract must NOT override a mutating command or operation.
    # Any mutating signal requires approval, regardless of contract type.
    requires_approval? =
      mutating_contract?(contract) or
        mutating_shell_command?(command) or
        mutating_operation?(operation)

    if requires_approval? and approval_status != :approved do
      details = approval_error_details(contract, command, operation, approval_status)
      {:error, {:parity_violation, {:approval_required_for_mutation, details}}}
    else
      :ok
    end
  end

  defp mutating_shell_command?(command) when is_list(command) and command != [] do
    case ShellPolicy.check_command(command) do
      {:ok, :read} -> false
      {:ok, _mutating_risk} -> true
      _ -> false
    end
  end

  defp mutating_shell_command?(_), do: false

  defp mutating_operation?(operation) when is_atom(operation) and not is_nil(operation) do
    operation in mutating_operations()
  end

  defp mutating_operation?(_), do: false

  defp approval_error_details(contract, command, operation, status) do
    cond do
      mutating_contract?(contract) ->
        %{contract: contract.name, approval_status: status}

      mutating_shell_command?(command) ->
        %{command: command, approval_status: status}

      mutating_operation?(operation) ->
        %{operation: operation, approval_status: status}

      true ->
        %{approval_status: status}
    end
  end

  @doc """
  Checks that path-based operations stay within the workspace sandbox.

  Requires `cwd` and `workspace_root` for any operation that involves
  file paths. Denies cwd outside the workspace root, and denies
  `../` escape attempts. Fails closed when sandbox fields are missing
  for path-based operations.
  """
  @spec check_sandbox_parity(remote_context()) :: parity_result()
  def check_sandbox_parity(context) when is_map(context) do
    cwd = Map.get(context, :cwd)
    workspace_root = Map.get(context, :workspace_root)

    # Only enforce sandbox when path-based fields are present
    # or when the operation type requires it.
    if requires_sandbox?(context) do
      cond do
        is_nil(cwd) ->
          {:error, {:parity_violation, {:sandbox_violation, :missing_cwd}}}

        is_nil(workspace_root) ->
          {:error, {:parity_violation, {:sandbox_violation, :missing_workspace_root}}}

        escape_attempt?(cwd) ->
          {:error, {:parity_violation, {:sandbox_violation, :path_traversal_detected}}}

        not within_workspace?(cwd, workspace_root) ->
          {:error, {:parity_violation, {:sandbox_violation, :cwd_outside_workspace}}}

        true ->
          :ok
      end
    else
      :ok
    end
  end

  @doc """
  Returns a summary of which parity gates apply for a given trust level.

  Useful for logging, diagnostics, and audit without leaking secrets.
  Reports the actual implementation state — gates that are enforced
  are marked `true`, others are marked with their current status.
  """
  @spec parity_summary(trust_level()) :: map()
  def parity_summary(trust_level)
      when trust_level in [:local, :trusted_remote, :untrusted_remote] do
    %{
      trust_level: trust_level,
      active_task_required: true,
      category_gate_applies: true,
      shell_policy_applies: true,
      env_policy_applies: :enforced_with_default_deny,
      approval_parity: :requires_approval_status,
      sandbox_parity: :enforced_for_path_operations,
      trust_constraints: TrustBoundary.summarize(trust_level)
    }
  end

  # -- Private helpers --

  defp valid_task_id?(id) when is_binary(id) and byte_size(id) > 0, do: true
  defp valid_task_id?(_), do: false

  defp valid_task_category?(cat) when is_atom(cat) and not is_nil(cat), do: true
  defp valid_task_category?(_), do: false

  defp build_gate_context(context) do
    %{
      mode: Map.get(context, :mode),
      task_category: Map.get(context, :task_category),
      task_id: Map.get(context, :task_id)
    }
  end

  defp infer_operation(context) do
    command = Map.get(context, :command)
    contract = Map.get(context, :contract)

    cond do
      command && mutating_command?(command) ->
        :execute_commands

      contract && not contract.read_only ->
        infer_operation_from_contract(contract)

      command && is_list(command) ->
        :read_files

      true ->
        :read_status
    end
  end

  defp mutating_command?(command) when is_list(command) and command != [] do
    case ShellPolicy.check_command(command) do
      {:ok, risk} when risk in [:medium, :high] -> true
      _ -> false
    end
  end

  defp mutating_command?(_), do: false

  defp infer_operation_from_contract(%Contract{execution: %{executes_code: true}}) do
    :execute_commands
  end

  defp infer_operation_from_contract(%Contract{execution: %{mutates_workspace: true}}) do
    :write_scoped_files
  end

  defp infer_operation_from_contract(_contract) do
    :read_files
  end

  defp validate_allowlist_only(allowlist) do
    case EnvPolicy.validate_allowlist(allowlist) do
      {:ok, _validated} ->
        :ok

      {:error, reason} ->
        {:error, {:parity_violation, {:env_policy_denied, reason}}}
    end
  end

  defp check_env_map_keys(env_map, allowlist) do
    # Validate the allowlist first
    case EnvPolicy.validate_allowlist(allowlist) do
      {:ok, validated} ->
        allowed_set = MapSet.new(validated)
        extra_keys = env_map |> Map.keys() |> Enum.reject(&MapSet.member?(allowed_set, &1))

        if extra_keys == [] do
          :ok
        else
          {:error,
           {:parity_violation, {:env_policy_denied, {:keys_outside_allowlist, extra_keys}}}}
        end

      {:error, reason} ->
        {:error, {:parity_violation, {:env_policy_denied, reason}}}
    end
  end

  # Sandbox helpers

  defp requires_sandbox?(context) do
    # Any path-based context requires sandbox enforcement.
    # This includes: cwd/workspace_root explicitly set,
    # contracts that mutate workspace, write operations,
    # shell commands (they always run somewhere), or
    # operations that require sandbox by nature.
    not is_nil(Map.get(context, :cwd)) or
      not is_nil(Map.get(context, :workspace_root)) or
      mutating_contract?(Map.get(context, :contract)) or
      shell_command?(Map.get(context, :command)) or
      operation_requires_sandbox?(Map.get(context, :operation))
  end

  defp shell_command?(command) when is_list(command) and command != [], do: true
  defp shell_command?(_), do: false

  defp operation_requires_sandbox?(operation) when is_atom(operation) and not is_nil(operation) do
    operation in mutating_operations()
  end

  defp operation_requires_sandbox?(_), do: false

  defp mutating_operations do
    # Operations that mutate the workspace or execute code —
    # these always require sandbox containment.
    [
      :write_files,
      :install_packages,
      :full_shell,
      :manage_services,
      :execute_commands,
      :write_scoped_files,
      :deploy_releases
    ]
  end

  defp mutating_contract?(%Contract{read_only: false}), do: true
  defp mutating_contract?(_), do: false

  defp escape_attempt?(cwd) when is_binary(cwd) do
    String.contains?(cwd, "../")
  end

  defp escape_attempt?(_), do: false

  defp within_workspace?(cwd, workspace_root) when is_binary(cwd) and is_binary(workspace_root) do
    # Normalize both paths for comparison
    normalized_cwd = Path.expand(cwd)
    normalized_root = Path.expand(workspace_root)

    # Must be exact match or have a separator after the root —
    # prevents /workspace/project_evil from matching /workspace/project.
    normalized_cwd == normalized_root or
      String.starts_with?(normalized_cwd, normalized_root <> "/")
  end

  defp within_workspace?(_, _), do: false
end
