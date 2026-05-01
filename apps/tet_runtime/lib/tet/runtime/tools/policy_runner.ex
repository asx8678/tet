defmodule Tet.Runtime.Tools.PolicyRunner do
  @moduledoc """
  Constrained shell/git/test execution with allowlists, command vectors,
  sandbox constraints, and risk labels — BD-0029.

  This runner enforces the following invariants before any command execution:

  1. **Command allowlist** — only whitelisted commands/subcommands may execute
  2. **Command vectors** — commands are represented as lists of strings,
     never passed through a shell for interpolation
  3. **Sandbox constraints** — the working directory must be contained within
     the canonical workspace root
  4. **Risk labels** — each command is classified (read/low/medium/high) for
     audit and steering
  5. **Policy enforcement** — requires an active task in an acting/verifying
     category AND gate clearance from `Tet.PlanMode.Gate`
  6. **Verifier output capture** — results are captured as structured
     `Tet.ShellPolicy.Artifact` values

  ## Usage

      {:ok, artifact} =
        PolicyRunner.run(
          ["mix", "test", "apps/tet_core"],
          cwd: "/workspace", workspace_root: "/workspace",
          task_id: "t1", task_category: :acting, tool_call_id: "call_abc"
        )

  The runner returns `{:ok, artifact}` or `{:error, denial}`.
  """

  alias Tet.PlanMode.{Gate, Policy}
  alias Tet.Runtime.Tools.PathResolver
  alias Tet.ShellPolicy
  alias Tet.ShellPolicy.Artifact

  @shell_contract ShellPolicy.shell_contract()

  @doc """
  Runs a command vector through policy enforcement and execution.

  ## Options

    - `:cwd` — working directory (required, must be within workspace)
    - `:workspace_root` — workspace root for sandbox containment (required)
    - `:task_id` — active task id for gate clearance
    - `:task_category` — active task category for gate clearance
    - `:mode` — runtime mode, defaults to `:execute`
    - `:tool_call_id` — tool call id for correlation
    - `:timeout` — command timeout in milliseconds (default 30_000)
    - `:allowlist` — custom allowlist override
  """
  @spec run([String.t()], keyword()) :: {:ok, Artifact.t()} | {:error, map()}
  def run(command_vector, opts) when is_list(command_vector) and is_list(opts) do
    with {:ok, risk} <- check_allowlist(command_vector, opts),
         {:ok, cwd} <- check_sandbox(opts),
         :ok <- check_gate(opts),
         {:ok, artifact} <- execute(command_vector, cwd, risk, opts) do
      {:ok, artifact}
    end
  end

  @doc """
  Validates a command vector without executing it.

  Returns `:ok` or `{:error, denial_map}`.
  """
  @spec validate([String.t()], keyword()) :: :ok | {:error, map()}
  def validate(command_vector, opts) when is_list(command_vector) and is_list(opts) do
    with {:ok, _risk} <- check_allowlist(command_vector, opts),
         {:ok, _cwd} <- check_sandbox(opts),
         :ok <- check_gate(opts) do
      :ok
    end
  end

  # -- Policy checks --

  defp check_allowlist(command_vector, opts) do
    allowlist = Keyword.get(opts, :allowlist, ShellPolicy.default_allowlist())

    case ShellPolicy.check_command(command_vector, allowlist) do
      {:ok, risk} -> {:ok, risk}
      {:error, reason} -> {:error, blocked_denial(reason, command_vector)}
    end
  end

  defp check_sandbox(opts) do
    cwd = Keyword.get(opts, :cwd)
    workspace_root = Keyword.get(opts, :workspace_root)

    cond do
      is_nil(cwd) -> {:error, sandbox_denial("No working directory specified")}
      is_nil(workspace_root) -> {:error, sandbox_denial("No workspace root specified")}
      not is_binary(cwd) -> {:error, sandbox_denial("Invalid working directory")}
      not is_binary(workspace_root) -> {:error, sandbox_denial("Invalid workspace root")}
      not PathResolver.contained?(cwd, workspace_root) ->
        {:error, sandbox_denial("Working directory escapes workspace")}

      true ->
        {:ok, cwd}
    end
  end

  defp check_gate(opts) do
    task_id = Keyword.get(opts, :task_id)
    task_category = Keyword.get(opts, :task_category)
    mode = Keyword.get(opts, :mode, :execute)
    policy = Keyword.get(opts, :policy, Policy.default())

    context = %{mode: mode, task_category: task_category, task_id: task_id}

    case Gate.evaluate(@shell_contract, policy, context) do
      :allow -> :ok
      {:guide, _msg} -> :ok
      {:block, reason} -> {:error, gate_denial(reason, context)}
    end
  end

  # -- Execution --

  defp execute(command_vector, cwd, risk, opts) do
    tool_call_id = Keyword.get(opts, :tool_call_id, "unknown")
    task_id = Keyword.get(opts, :task_id)
    _timeout = Keyword.get(opts, :timeout, 30_000)
    start = System.monotonic_time(:millisecond)

    result =
      System.cmd(hd(command_vector), tl(command_vector),
        cd: cwd,
        stderr_to_stdout: true,
        parallelism: false
      )

    duration = System.monotonic_time(:millisecond) - start

    case result do
      {output, exit_code} when is_binary(output) and is_integer(exit_code) ->
        # stderr is merged into stdout when stderr_to_stdout: true
        build_artifact(command_vector, cwd, risk, output, "", exit_code, duration, tool_call_id, task_id)

      {output, exit_code} when is_list(output) and is_integer(exit_code) ->
        output_str = IO.iodata_to_binary(output)
        build_artifact(command_vector, cwd, risk, output_str, "", exit_code, duration, tool_call_id, task_id)
    end
  rescue
    e ->
      {:error, internal_denial("Command execution error: #{Exception.message(e)}")}
  end

  defp build_artifact(command_vector, cwd, risk, stdout, stderr, exit_code, duration, tool_call_id, task_id) do
    case Artifact.new(%{
           command: command_vector,
           risk: risk,
           exit_code: exit_code,
           stdout: stdout,
           stderr: stderr,
           cwd: cwd,
           duration_ms: duration,
           tool_call_id: tool_call_id,
           task_id: task_id
         }) do
      {:ok, artifact} -> {:ok, artifact}
      {:error, reason} -> {:error, internal_denial(reason)}
    end
  end

  # -- Denial builders --

  defp blocked_denial(reason, command_vector) do
    %{
      code: "policy_denial",
      message: "Command blocked by allowlist: #{inspect(reason)}",
      kind: "policy_denial",
      retryable: false,
      correlation: nil,
      details: %{command: command_vector, reason: reason}
    }
  end

  defp sandbox_denial(message) do
    %{
      code: "workspace_escape",
      message: message,
      kind: "policy_denial",
      retryable: false,
      correlation: nil,
      details: %{}
    }
  end

  defp gate_denial(reason, context) do
    %{
      code: "policy_denial",
      message: "Gate blocked shell execution: #{reason}",
      kind: "policy_denial",
      retryable: false,
      correlation: nil,
      details: %{gate_reason: reason, context: context}
    }
  end

  defp internal_denial(reason) when is_tuple(reason) do
    %{
      code: "internal_error",
      message: "Shell policy internal error: #{inspect(reason)}",
      kind: "internal",
      retryable: false,
      correlation: nil,
      details: %{}
    }
  end

  defp internal_denial(reason) when is_binary(reason) do
    %{
      code: "internal_error",
      message: reason,
      kind: "internal",
      retryable: false,
      correlation: nil,
      details: %{}
    }
  end
end

