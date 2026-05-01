defmodule Tet.Repair.PatchWorkflow.GateTest do
  use ExUnit.Case, async: true

  @moduletag :tet_core

  alias Tet.Repair.PatchWorkflow
  alias Tet.Repair.PatchWorkflow.Gate

  @valid_plan %{
    description: "Fix the broken parser",
    files: ["lib/parser.ex"],
    changes: [%{file: "lib/parser.ex", action: :replace}]
  }

  @valid_attrs %{
    repair_id: "rep_001",
    session_id: "ses_001",
    plan: @valid_plan
  }

  defp build_workflow(status, opts \\ []) do
    {:ok, wf} = PatchWorkflow.new(@valid_attrs)

    wf =
      case status do
        :pending_approval ->
          wf

        :approved ->
          {:ok, wf} = PatchWorkflow.approve(wf, "apr_001")

          if Keyword.get(opts, :checkpoint) do
            {:ok, wf} = PatchWorkflow.take_checkpoint(wf, "cp_001")
            wf
          else
            wf
          end

        :patching ->
          {:ok, wf} = PatchWorkflow.approve(wf, "apr_001")
          {:ok, wf} = PatchWorkflow.take_checkpoint(wf, "cp_001")
          {:ok, wf} = PatchWorkflow.begin_patching(wf)
          wf

        :succeeded ->
          {:ok, wf} = PatchWorkflow.approve(wf, "apr_001")
          {:ok, wf} = PatchWorkflow.take_checkpoint(wf, "cp_001")
          {:ok, wf} = PatchWorkflow.begin_patching(wf)
          {:ok, wf} = PatchWorkflow.succeed(wf)
          wf

        :failed ->
          {:ok, wf} = PatchWorkflow.approve(wf, "apr_001")
          {:ok, wf} = PatchWorkflow.take_checkpoint(wf, "cp_001")
          {:ok, wf} = PatchWorkflow.begin_patching(wf)
          {:ok, wf} = PatchWorkflow.fail(wf, "boom")
          wf

        :rejected ->
          {:ok, wf} = PatchWorkflow.reject(wf)
          wf

        :rolled_back ->
          {:ok, wf} = PatchWorkflow.approve(wf, "apr_001")
          {:ok, wf} = PatchWorkflow.take_checkpoint(wf, "cp_001")
          {:ok, wf} = PatchWorkflow.begin_patching(wf)
          {:ok, wf} = PatchWorkflow.fail(wf, "boom")
          {:ok, wf} = PatchWorkflow.rollback(wf)
          wf
      end

    wf
  end

  # -- can_patch?/1 --------------------------------------------------------

  describe "can_patch?/1" do
    test "true when approved with checkpoint" do
      wf = build_workflow(:approved, checkpoint: true)
      assert Gate.can_patch?(wf)
    end

    test "false when approved without checkpoint" do
      wf = build_workflow(:approved)
      refute Gate.can_patch?(wf)
    end

    test "false when pending_approval" do
      wf = build_workflow(:pending_approval)
      refute Gate.can_patch?(wf)
    end

    test "false when already patching" do
      wf = build_workflow(:patching)
      refute Gate.can_patch?(wf)
    end

    test "false when rejected" do
      wf = build_workflow(:rejected)
      refute Gate.can_patch?(wf)
    end

    test "false when succeeded" do
      wf = build_workflow(:succeeded)
      refute Gate.can_patch?(wf)
    end

    test "false when failed" do
      wf = build_workflow(:failed)
      refute Gate.can_patch?(wf)
    end

    test "false when rolled_back" do
      wf = build_workflow(:rolled_back)
      refute Gate.can_patch?(wf)
    end
  end

  # -- can_approve?/1 ------------------------------------------------------

  describe "can_approve?/1" do
    test "true when pending_approval" do
      wf = build_workflow(:pending_approval)
      assert Gate.can_approve?(wf)
    end

    test "false when approved" do
      wf = build_workflow(:approved)
      refute Gate.can_approve?(wf)
    end

    test "false when rejected" do
      wf = build_workflow(:rejected)
      refute Gate.can_approve?(wf)
    end

    test "false for all non-pending statuses" do
      for status <- [:approved, :patching, :succeeded, :failed, :rejected, :rolled_back] do
        wf = build_workflow(status, checkpoint: true)
        refute Gate.can_approve?(wf), "expected false for #{status}"
      end
    end
  end

  # -- needs_checkpoint?/1 -------------------------------------------------

  describe "needs_checkpoint?/1" do
    test "true when approved without checkpoint" do
      wf = build_workflow(:approved)
      assert Gate.needs_checkpoint?(wf)
    end

    test "false when approved with checkpoint" do
      wf = build_workflow(:approved, checkpoint: true)
      refute Gate.needs_checkpoint?(wf)
    end

    test "false when pending_approval" do
      wf = build_workflow(:pending_approval)
      refute Gate.needs_checkpoint?(wf)
    end

    test "false when patching (checkpoint already taken)" do
      wf = build_workflow(:patching)
      refute Gate.needs_checkpoint?(wf)
    end
  end

  # -- validate_preconditions/1 --------------------------------------------

  describe "validate_preconditions/1" do
    test "ok when all preconditions met" do
      wf = build_workflow(:approved, checkpoint: true)

      assert {:ok, ^wf} = Gate.validate_preconditions(wf)
    end

    test "error with :not_approved when pending" do
      wf = build_workflow(:pending_approval)

      assert {:error, reasons} = Gate.validate_preconditions(wf)
      assert :not_approved in reasons
    end

    test "error with :missing_checkpoint when no checkpoint" do
      wf = build_workflow(:approved)

      assert {:error, reasons} = Gate.validate_preconditions(wf)
      assert :missing_checkpoint in reasons
    end

    test "error with :missing_approval when no approval_id" do
      # Manually build a struct in approved status but without approval_id
      # (normally impossible via the API, but validates the gate thoroughly)
      {:ok, %PatchWorkflow{} = wf} = PatchWorkflow.new(@valid_attrs)
      wf = %{wf | status: :approved, checkpoint_id: "cp_001"}

      assert {:error, reasons} = Gate.validate_preconditions(wf)
      assert :missing_approval in reasons
    end

    test "collects multiple failing reasons" do
      wf = build_workflow(:pending_approval)

      assert {:error, reasons} = Gate.validate_preconditions(wf)
      assert :not_approved in reasons
      assert :missing_checkpoint in reasons
      assert :missing_approval in reasons
    end

    test "does not include :missing_plan for valid workflows" do
      wf = build_workflow(:approved, checkpoint: true)

      assert {:ok, _} = Gate.validate_preconditions(wf)
    end

    test ":missing_plan when plan is nil" do
      {:ok, %PatchWorkflow{} = wf} = PatchWorkflow.new(@valid_attrs)

      wf = %{wf | status: :approved, approval_id: "apr_001", checkpoint_id: "cp_001", plan: nil}

      assert {:error, reasons} = Gate.validate_preconditions(wf)
      assert :missing_plan in reasons
    end
  end

  # -- Integration: gate + workflow transitions ----------------------------

  describe "gate enforcement integration" do
    test "cannot begin_patching without approval (gate confirms)" do
      wf = build_workflow(:pending_approval)

      refute Gate.can_patch?(wf)
      assert {:error, _} = PatchWorkflow.begin_patching(wf)
    end

    test "cannot begin_patching without checkpoint (gate confirms)" do
      wf = build_workflow(:approved)

      refute Gate.can_patch?(wf)
      assert Gate.needs_checkpoint?(wf)
      assert {:error, :checkpoint_required_before_patching} = PatchWorkflow.begin_patching(wf)
    end

    test "can begin_patching only when gate passes" do
      wf = build_workflow(:approved, checkpoint: true)

      assert Gate.can_patch?(wf)
      assert {:ok, _} = Gate.validate_preconditions(wf)
      assert {:ok, patching} = PatchWorkflow.begin_patching(wf)
      assert patching.status == :patching
    end
  end
end
