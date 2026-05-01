defmodule Tet.ShellPolicy do
  @moduledoc """
  Shell/git/test policy runner — pure data and decision types — BD-0029.

  Defines the command allowlist, risk labels, sandbox constraints, and
  artifact shape for constrained shell/git/test execution. This module is
  the map, not the robot driving the car: it describes what is allowed,
  how risky it is, and what an artifact looks like. The actual execution
  happens in `tet_runtime`.

  ## Allowlist design

  Only whitelisted commands may execute. Each allowlist entry declares:

    - `command` — the executable name (e.g., `"git"`, `"mix"`)
    - `subcommands` — a list of allowed subcommand prefixes (e.g.,
      `["status", "log", "test"]`). An empty list means any subcommand is
      allowed for that executable.
    - `risk` — one of `:read`, `:low`, `:medium`, `:high`

  ## Risk labels

    - `:read` — read-only inspection (git status, git log, git diff)
    - `:low` — safe mutations (git add, mix format)
    - `:medium` — build/test (mix test, mix compile)
    - `:high` — destructive mutations (git commit, git push, git reset)

  ## Sandbox constraints

  Every command execution must specify a working directory that is contained
  within the workspace root. This is enforced by `Tet.Runtime.Tools.PathResolver`.

  ## Policy enforcement

  Execution requires:
    1. An active task with category in `[:acting, :verifying, :debugging]`
    2. Gate clearance from `Tet.PlanMode.Gate` for the shell contract

  ## Verifier output artifact

  Test/verifier results are captured as structured artifacts:

      %Tet.ShellPolicy.Artifact{
        command: ["mix", "test"],
        risk: :medium,
        exit_code: 0,
        stdout: "...",
        stderr: "...",
        cwd: "/workspace/apps/tet_core",
        duration_ms: 1_234,
        tool_call_id: "call_abc123",
        task_id: "t1"
      }
  """

  @risk_levels [:read, :low, :medium, :high]
  @acting_categories [:acting, :verifying, :debugging]

  @doc "Returns all valid risk levels."
  @spec risk_levels() :: [:read | :low | :medium | :high]
  def risk_levels, do: @risk_levels

  @doc "Returns the task categories that permit shell/git execution."
  @spec acting_categories() :: [:acting | :verifying | :debugging]
  def acting_categories, do: @acting_categories

  @doc """
  Returns the default command allowlist.

  Each entry is a map with `:command`, `:subcommands`, and `:risk` keys.
  Subcommands must match exactly (no prefix matching) — `["test"]` matches
  `["mix", "test"]` and `["mix", "test", "apps/tet_core"]` (the first
  argument after the executable is matched exactly).
  """
  @spec default_allowlist() :: [map()]
  def default_allowlist do
    [
      %{command: "git", subcommands: ~w(status log diff show branch), risk: :read},
      %{command: "git", subcommands: ~w(add restore), risk: :low},
      %{command: "git", subcommands: ~w(commit push pull fetch merge rebase), risk: :high},
      %{command: "git", subcommands: ~w(checkout reset clean stash), risk: :high},
      %{command: "git", subcommands: ~w(init remote), risk: :medium},
      %{command: "mix", subcommands: ~w(test), risk: :medium},
      %{command: "mix", subcommands: ~w(compile), risk: :medium},
      %{command: "mix", subcommands: ~w(format), risk: :low},
      %{command: "mix", subcommands: ~w(deps.get deps.compile), risk: :medium},
      %{command: "mix", subcommands: ~w(run), risk: :medium},
      %{command: "mix", subcommands: ~w(phx.new), risk: :high}
    ]
  end

  @doc """
  Validates a command vector against the allowlist.

  Returns `{:ok, risk_level}` when the command is allowed, or
  `{:error, {:blocked_command, reason}}` when it is not.

  ## Examples

      iex> Tet.ShellPolicy.check_command(["git", "status"])
      {:ok, :read}

      iex> Tet.ShellPolicy.check_command(["rm", "-rf", "/"])
      {:error, {:blocked_command, :unknown_executable}}

      iex> Tet.ShellPolicy.check_command(["git", "push", "--force"])
      {:ok, :high}
  """
  @spec check_command([String.t()]) :: {:ok, :read | :low | :medium | :high} | {:error, term()}
  def check_command(command_vector, allowlist \\ nil) when is_list(command_vector) do
    allowlist = allowlist || default_allowlist()

    with :ok <- validate_vector(command_vector),
         {:ok, executable} <- fetch_executable(command_vector),
         {:ok, subcommand} <- fetch_subcommand(command_vector),
         {:ok, entry} <- find_entry(allowlist, executable, subcommand) do
      {:ok, entry.risk}
    end
  end

  @doc """
  Returns true when the command vector is allowed by the allowlist.
  """
  @spec allowed?([String.t()]) :: boolean()
  def allowed?(command_vector, allowlist \\ nil) do
    case check_command(command_vector, allowlist) do
      {:ok, _risk} -> true
      {:error, _} -> false
    end
  end

  @doc """
  Returns the shell contract for gate clearance checks.

  The shell contract declares modes `[:execute]` and task categories
  `[:acting, :verifying, :debugging]`, matching the BD-0025 gate
  requirements for mutating tools.
  """
  @spec shell_contract() :: Contract.t()
  def shell_contract do
    {:ok, base} = Tet.Tool.ReadOnlyContracts.fetch("read")

    %{
      base
      | name: "shell-policy",
        read_only: false,
        mutation: :execute,
        modes: [:execute],
        task_categories: [:acting, :verifying, :debugging],
        execution: %{
          base.execution
          | executes_code: true,
            mutates_workspace: true,
            status: :contract_only,
            effects: [:executes_shell_command, :run_test]
        }
    }
  end

  @doc """
  Determines if the current task category permits shell execution.

  Shell execution requires an active task in an acting category
  (`:acting`, `:verifying`, or `:debugging`).
  """
  @spec acting_category?(atom() | nil) :: boolean()
  def acting_category?(category) when is_atom(category), do: category in @acting_categories
  def acting_category?(nil), do: false

  # -- Private helpers --

  defp validate_vector([]), do: {:error, {:blocked_command, :empty_vector}}
  defp validate_vector([head | _]) when is_binary(head), do: :ok

  defp validate_vector(_list), do: {:error, {:blocked_command, :invalid_vector}}

  defp fetch_executable([executable | _]) when is_binary(executable) and executable != "",
    do: {:ok, executable}

  defp fetch_executable(_vector), do: {:error, {:blocked_command, :unknown_executable}}

  defp fetch_subcommand([_executable | rest]) when rest == [], do: {:ok, nil}
  defp fetch_subcommand([_executable | rest]), do: {:ok, hd(rest)}

  defp find_entry(allowlist, executable, nil) do
    case Enum.find(allowlist, &(&1.command == executable and &1.subcommands == [])) do
      nil ->
        # Check if any entry exists for this executable at all
        if Enum.any?(allowlist, &(&1.command == executable)) do
          {:error, {:blocked_command, :subcommand_required}}
        else
          {:error, {:blocked_command, :unknown_executable}}
        end

      entry ->
        {:ok, entry}
    end
  end

  defp find_entry(allowlist, executable, subcommand) do
    case Enum.find(allowlist, fn entry ->
           entry.command == executable and
             (entry.subcommands == [] or
                Enum.any?(entry.subcommands, fn allowed ->
                  subcommand == allowed
                end))
         end) do
      nil ->
        if Enum.any?(allowlist, &(&1.command == executable)) do
          {:error, {:blocked_command, :subcommand_not_allowed}}
        else
          {:error, {:blocked_command, :unknown_executable}}
        end

      entry ->
        {:ok, entry}
    end
  end
end
