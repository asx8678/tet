defmodule Tet.PlanMode.GateTestHelpers do
  @moduledoc """
  Shared test fixtures for Tet.PlanMode.GateTest.

  Extracted from gate_test.exs to keep the test file focused on
  assertions and below the 600-line guideline.
  """

  alias Tet.Tool.Contract
  alias Tet.Tool.ReadOnlyContracts

  # -- Read-only contract fixtures --

  def read_contract do
    {:ok, c} = ReadOnlyContracts.fetch("read")
    c
  end

  def list_contract do
    {:ok, c} = ReadOnlyContracts.fetch("list")
    c
  end

  def search_contract do
    {:ok, c} = ReadOnlyContracts.fetch("search")
    c
  end

  def ask_user_contract do
    {:ok, c} = ReadOnlyContracts.fetch("ask-user")
    c
  end

  # -- Context fixtures --

  def plan_research_ctx do
    %{mode: :plan, task_category: :researching, task_id: "t1"}
  end

  def plan_planning_ctx do
    %{mode: :plan, task_category: :planning, task_id: "t2"}
  end

  def execute_acting_ctx do
    %{mode: :execute, task_category: :acting, task_id: "t3"}
  end

  def explore_research_ctx do
    %{mode: :explore, task_category: :researching, task_id: "t4"}
  end

  def relaxed_policy do
    Tet.PlanMode.Policy.new!(%{require_active_task: false})
  end

  # -- Mutating contract fixtures --

  def write_contract do
    %Contract{} = base = read_contract()

    %{
      base
      | name: "write-file",
        read_only: false,
        mutation: :write,
        modes: [:execute, :repair],
        task_categories: [:acting, :verifying, :debugging],
        execution: %{
          base.execution
          | mutates_workspace: true,
            executes_code: false,
            status: :contract_only,
            effects: [:writes_file]
        }
    }
  end

  def shell_contract do
    %Contract{} = base = read_contract()

    %{
      base
      | name: "shell",
        read_only: false,
        mutation: :execute,
        modes: [:execute],
        task_categories: [:acting, :debugging],
        execution: %{
          base.execution
          | executes_code: true,
            mutates_workspace: true,
            status: :contract_only,
            effects: [:executes_shell_command]
        }
    }
  end

  def rogue_plan_write_contract do
    %Contract{} = base = read_contract()

    %{
      base
      | name: "rogue-plan-write",
        read_only: false,
        mutation: :write,
        modes: [:plan, :explore, :execute],
        task_categories: [:acting, :verifying, :debugging],
        execution: %{
          base.execution
          | mutates_workspace: true,
            executes_code: false,
            status: :contract_only,
            effects: [:writes_file]
        }
    }
  end

  def rogue_plan_shell_contract do
    %Contract{} = base = read_contract()

    %{
      base
      | name: "rogue-plan-shell",
        read_only: false,
        mutation: :execute,
        modes: [:plan, :execute],
        task_categories: [:acting, :debugging],
        execution: %{
          base.execution
          | executes_code: true,
            mutates_workspace: true,
            status: :contract_only,
            effects: [:executes_shell_command]
        }
    }
  end

  def verifying_only_write_contract do
    %Contract{} = base = read_contract()

    %{
      base
      | name: "verifying-only-write",
        read_only: false,
        mutation: :write,
        modes: [:execute, :repair],
        task_categories: [:verifying, :debugging],
        execution: %{
          base.execution
          | mutates_workspace: true,
            executes_code: false,
            status: :contract_only,
            effects: [:writes_file]
        }
    }
  end

  @doc """
  A read-only contract that only declares [:planning] in task_categories,
  intentionally omitting other runtime categories like :researching and :acting.
  Used to verify that contract_allows_category? is enforced as an independent
  prerequisite for read-only contracts (BD-0025 QA regression).
  """
  def read_only_planning_only_contract do
    %Contract{} = base = read_contract()

    %{base | name: "read-planning-only", task_categories: [:planning]}
  end

  @doc """
  Build a simulated mutating write contract that only declares [:verifying]
  in task_categories — omits :acting. Used to verify that read-only shortcuts
  don't bypass contract_allows_category? (BD-0025 QA regression).
  """
  def write_verifying_only_contract do
    %Contract{} = base = read_contract()

    %{
      base
      | name: "write-verifying-only",
        read_only: false,
        mutation: :write,
        modes: [:execute, :repair],
        task_categories: [:verifying],
        execution: %{
          base.execution
          | mutates_workspace: true,
            executes_code: false,
            status: :contract_only,
            effects: [:writes_file]
        }
    }
  end

  @doc """
  A read-only contract that only declares [:acting] in task_categories,
  intentionally omitting plan-safe categories like :researching and :planning.
  Used to verify that contract_allows_category? is enforced as an independent
  prerequisite for read-only contracts in acting-heavy contexts (BD-0025 QA).
  """
  def read_only_acting_only_contract do
    %Contract{} = base = read_contract()

    %{base | name: "read-acting-only", task_categories: [:acting]}
  end

  def string_metadata_contract do
    base_attrs = read_contract() |> Map.from_struct()

    attrs =
      base_attrs
      |> Map.put(:modes, ["plan", "explore", "execute", "repair"])
      |> Map.put(:task_categories, ["researching", "planning", "acting"])

    {:ok, contract} = Contract.new(attrs)
    contract
  end

  # -- BD-0026 invariant helpers --

  @doc """
  A policy struct with empty safe_modes, bypassing Policy.new/1 validation.
  Used to verify the gate fails closed when policy data is missing.
  """
  def empty_safe_modes_policy do
    struct(Tet.PlanMode.Policy, %{
      plan_mode: :plan,
      safe_modes: [],
      plan_safe_categories: [:researching, :planning],
      acting_categories: [:acting, :verifying, :debugging, :documenting],
      require_active_task: true
    })
  end

  @doc """
  A policy struct with empty plan_safe_categories, bypassing validation.
  Tests fail-closed behavior when category data is absent.
  """
  def empty_plan_safe_categories_policy do
    struct(Tet.PlanMode.Policy, %{
      plan_mode: :plan,
      safe_modes: [:plan, :explore],
      plan_safe_categories: [],
      acting_categories: [:acting, :verifying, :debugging, :documenting],
      require_active_task: true
    })
  end

  @doc """
  A policy struct with nil safe_modes, bypassing validation.
  Tests the most extreme fail-closed edge case.
  """
  def nil_safe_modes_policy do
    struct(Tet.PlanMode.Policy, %{
      plan_mode: :plan,
      safe_modes: nil,
      plan_safe_categories: [:researching, :planning],
      acting_categories: [:acting, :verifying, :debugging, :documenting],
      require_active_task: true
    })
  end
end
