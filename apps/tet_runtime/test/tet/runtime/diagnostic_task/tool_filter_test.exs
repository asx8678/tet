defmodule Tet.Runtime.DiagnosticTask.ToolFilterTest do
  use ExUnit.Case, async: true

  alias Tet.Runtime.DiagnosticTask
  alias Tet.Runtime.DiagnosticTask.ToolFilter

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp build_error(overrides \\ %{}) do
    struct(
      Tet.ErrorLog,
      Map.merge(
        %{
          id: "err_001",
          session_id: "ses_001",
          kind: :exception,
          message: "Something went wrong",
          status: :open
        },
        overrides
      )
    )
  end

  defp build_diagnostic_task do
    error = build_error()
    {:ok, task} = DiagnosticTask.new(error, "ses_001")
    task
  end

  defp build_repair_task do
    task = build_diagnostic_task()
    {:ok, task} = DiagnosticTask.submit_plan(task, %{action: "fix"})
    {:ok, task} = DiagnosticTask.approve(task)
    {:ok, task} = DiagnosticTask.promote_to_repair(task)
    task
  end

  # ── filter_tools/2 ─────────────────────────────────────────────────────

  describe "filter_tools/2" do
    test "filters to only diagnostic tools in diagnostic mode" do
      task = build_diagnostic_task()

      all_tools = [
        :read,
        :search,
        :list,
        :doctor,
        :error_log_inspect,
        :patch,
        :write,
        :shell,
        :deploy
      ]

      filtered = ToolFilter.filter_tools(all_tools, task)

      assert :read in filtered
      assert :search in filtered
      assert :list in filtered
      assert :doctor in filtered
      assert :error_log_inspect in filtered
      refute :patch in filtered
      refute :write in filtered
      refute :shell in filtered
      refute :deploy in filtered
    end

    test "allows all tools in repair mode" do
      task = build_repair_task()
      all_tools = [:read, :search, :patch, :write, :shell, :deploy]

      filtered = ToolFilter.filter_tools(all_tools, task)

      assert filtered == all_tools
    end

    test "handles string tool names" do
      task = build_diagnostic_task()
      tools = ["read", "patch", "search", "write"]

      filtered = ToolFilter.filter_tools(tools, task)

      assert "read" in filtered
      assert "search" in filtered
      refute "patch" in filtered
      refute "write" in filtered
    end

    test "returns empty list when no tools are allowed" do
      task = build_diagnostic_task()
      assert ToolFilter.filter_tools([:patch, :write, :shell], task) == []
    end

    test "returns empty list for empty input" do
      task = build_diagnostic_task()
      assert ToolFilter.filter_tools([], task) == []
    end

    test "preserves order of allowed tools" do
      task = build_diagnostic_task()
      tools = [:search, :patch, :read, :write, :list]

      assert ToolFilter.filter_tools(tools, task) == [:search, :read, :list]
    end

    test "still blocks mutating tools during plan_ready status" do
      task = build_diagnostic_task()
      {:ok, task} = DiagnosticTask.submit_plan(task, %{action: "fix"})
      assert DiagnosticTask.status(task) == :plan_ready

      filtered = ToolFilter.filter_tools([:read, :patch], task)
      assert filtered == [:read]
    end

    test "still blocks mutating tools during repair_approved status" do
      task = build_diagnostic_task()
      {:ok, task} = DiagnosticTask.submit_plan(task, %{action: "fix"})
      {:ok, task} = DiagnosticTask.approve(task)
      assert DiagnosticTask.status(task) == :repair_approved

      filtered = ToolFilter.filter_tools([:read, :shell], task)
      assert filtered == [:read]
    end
  end

  # ── explain_blocked/2 ──────────────────────────────────────────────────

  describe "explain_blocked/2" do
    test "returns :allowed for permitted tools" do
      task = build_diagnostic_task()
      assert ToolFilter.explain_blocked(:read, task) == :allowed
      assert ToolFilter.explain_blocked(:search, task) == :allowed
    end

    test "returns explanation for blocked tools during diagnosing" do
      task = build_diagnostic_task()
      assert {:ok, reason} = ToolFilter.explain_blocked(:patch, task)
      assert String.contains?(reason, "patch")
      assert String.contains?(reason, "diagnostic mode")
    end

    test "returns explanation for blocked tools during plan_ready" do
      task = build_diagnostic_task()
      {:ok, task} = DiagnosticTask.submit_plan(task, %{action: "fix"})

      assert {:ok, reason} = ToolFilter.explain_blocked(:write, task)
      assert String.contains?(reason, "write")
      assert String.contains?(reason, "approved")
    end

    test "returns explanation for blocked tools during repair_approved" do
      task = build_diagnostic_task()
      {:ok, task} = DiagnosticTask.submit_plan(task, %{action: "fix"})
      {:ok, task} = DiagnosticTask.approve(task)

      assert {:ok, reason} = ToolFilter.explain_blocked(:shell, task)
      assert String.contains?(reason, "shell")
      assert String.contains?(reason, "promote")
    end

    test "returns :allowed for all tools in repair mode" do
      task = build_repair_task()

      for tool <- [:read, :patch, :write, :shell, :deploy] do
        assert ToolFilter.explain_blocked(tool, task) == :allowed,
               "expected #{tool} to be :allowed in repair mode"
      end
    end

    test "handles string tool names" do
      task = build_diagnostic_task()
      assert {:ok, _reason} = ToolFilter.explain_blocked("patch", task)
      assert ToolFilter.explain_blocked("read", task) == :allowed
    end
  end

  # ── tool_category/1 ────────────────────────────────────────────────────

  describe "tool_category/1" do
    test "categorizes diagnostic tools" do
      for tool <- [:read, :search, :list, :doctor, :error_log_inspect] do
        assert ToolFilter.tool_category(tool) == :diagnostic,
               "expected #{tool} to be :diagnostic"
      end
    end

    test "categorizes mutating tools" do
      for tool <- [:patch, :write, :shell, :deploy] do
        assert ToolFilter.tool_category(tool) == :mutating,
               "expected #{tool} to be :mutating"
      end
    end

    test "categorizes unknown tools as neutral" do
      assert ToolFilter.tool_category(:something_else) == :neutral
      assert ToolFilter.tool_category(:fancy_tool) == :neutral
    end

    test "handles string tool names" do
      assert ToolFilter.tool_category("read") == :diagnostic
      assert ToolFilter.tool_category("patch") == :mutating
    end

    test "is consistent with DiagnosticTask tool lists" do
      for tool <- DiagnosticTask.diagnostic_tools() do
        assert ToolFilter.tool_category(tool) == :diagnostic
      end

      for tool <- DiagnosticTask.blocked_tools() do
        assert ToolFilter.tool_category(tool) == :mutating
      end
    end
  end
end
