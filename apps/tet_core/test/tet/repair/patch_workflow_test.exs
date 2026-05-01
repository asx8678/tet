defmodule Tet.Repair.PatchWorkflowTest do
  use ExUnit.Case, async: true

  @moduletag :tet_core

  alias Tet.Repair.PatchWorkflow

  @valid_plan %{
    description: "Fix the broken parser",
    files: ["lib/parser.ex"],
    changes: [%{file: "lib/parser.ex", action: :replace, old: "bug", new: "fix"}]
  }

  @valid_attrs %{
    repair_id: "rep_001",
    session_id: "ses_001",
    plan: @valid_plan
  }

  # -- new/1 -----------------------------------------------------------

  describe "new/1" do
    test "builds a valid workflow with minimum required attrs" do
      assert {:ok, wf} = PatchWorkflow.new(@valid_attrs)

      assert String.starts_with?(wf.id, "pwf_")
      assert wf.repair_id == "rep_001"
      assert wf.session_id == "ses_001"
      assert wf.plan == @valid_plan
      assert wf.status == :pending_approval
      assert wf.patches_applied == []
      assert wf.checkpoint_id == nil
      assert wf.approval_id == nil
      assert %DateTime{} = wf.created_at
    end

    test "accepts explicit id" do
      attrs = Map.put(@valid_attrs, :id, "pwf_explicit")
      assert {:ok, wf} = PatchWorkflow.new(attrs)
      assert wf.id == "pwf_explicit"
    end

    test "auto-generates id when omitted" do
      assert {:ok, wf1} = PatchWorkflow.new(@valid_attrs)
      assert {:ok, wf2} = PatchWorkflow.new(@valid_attrs)
      assert wf1.id != wf2.id
    end

    test "session_id is optional" do
      attrs = Map.delete(@valid_attrs, :session_id)
      assert {:ok, wf} = PatchWorkflow.new(attrs)
      assert wf.session_id == nil
    end

    test "accepts string-keyed plan" do
      attrs = %{
        repair_id: "rep_002",
        plan: %{
          "description" => "string keys",
          "files" => ["lib/foo.ex"],
          "changes" => []
        }
      }

      assert {:ok, wf} = PatchWorkflow.new(attrs)
      assert wf.plan.description == "string keys"
    end

    test "rejects missing repair_id" do
      attrs = Map.delete(@valid_attrs, :repair_id)

      assert {:error, {:invalid_entity_field, :patch_workflow, :repair_id}} =
               PatchWorkflow.new(attrs)
    end

    test "rejects missing plan" do
      attrs = Map.delete(@valid_attrs, :plan)
      assert {:error, {:invalid_entity_field, :patch_workflow, :plan}} = PatchWorkflow.new(attrs)
    end

    test "rejects plan without required keys" do
      attrs = %{@valid_attrs | plan: %{description: "no files or changes"}}
      assert {:error, {:invalid_entity_field, :patch_workflow, :plan}} = PatchWorkflow.new(attrs)
    end

    test "rejects non-map input" do
      assert {:error, :invalid_patch_workflow} = PatchWorkflow.new("nope")
    end
  end

  # -- request_approval/2 -----------------------------------------------

  describe "request_approval/2" do
    test "records approval_id on a pending workflow" do
      {:ok, wf} = PatchWorkflow.new(@valid_attrs)

      assert {:ok, wf} = PatchWorkflow.request_approval(wf, "apr_001")
      assert wf.approval_id == "apr_001"
      assert wf.status == :pending_approval
    end

    test "rejects empty approval_id" do
      {:ok, wf} = PatchWorkflow.new(@valid_attrs)
      assert {:error, _} = PatchWorkflow.request_approval(wf, "")
    end

    test "rejects when not in pending_approval" do
      {:ok, wf} = PatchWorkflow.new(@valid_attrs)
      {:ok, wf} = PatchWorkflow.approve(wf, "apr_001")

      assert {:error, {:invalid_transition, :request_approval, :approved}} =
               PatchWorkflow.request_approval(wf, "apr_002")
    end
  end

  # -- approve/2 ---------------------------------------------------------

  describe "approve/2" do
    test "transitions from pending_approval to approved" do
      {:ok, wf} = PatchWorkflow.new(@valid_attrs)

      assert {:ok, wf} = PatchWorkflow.approve(wf, "apr_001")
      assert wf.status == :approved
      assert wf.approval_id == "apr_001"
    end

    test "rejects from non-pending status" do
      {:ok, wf} = PatchWorkflow.new(@valid_attrs)
      {:ok, wf} = PatchWorkflow.reject(wf)

      assert {:error, {:invalid_transition, :approve, :rejected}} =
               PatchWorkflow.approve(wf, "apr_001")
    end

    test "rejects empty approval_id" do
      {:ok, wf} = PatchWorkflow.new(@valid_attrs)
      assert {:error, _} = PatchWorkflow.approve(wf, "")
    end
  end

  # -- reject/1 ----------------------------------------------------------

  describe "reject/1" do
    test "transitions from pending_approval to rejected" do
      {:ok, wf} = PatchWorkflow.new(@valid_attrs)

      assert {:ok, wf} = PatchWorkflow.reject(wf)
      assert wf.status == :rejected
      assert %DateTime{} = wf.completed_at
    end

    test "rejects from non-pending status" do
      {:ok, wf} = PatchWorkflow.new(@valid_attrs)
      {:ok, wf} = PatchWorkflow.approve(wf, "apr_001")

      assert {:error, {:invalid_transition, :reject, :approved}} =
               PatchWorkflow.reject(wf)
    end
  end

  # -- take_checkpoint/2 -------------------------------------------------

  describe "take_checkpoint/2" do
    test "records checkpoint_id on an approved workflow" do
      {:ok, wf} = PatchWorkflow.new(@valid_attrs)
      {:ok, wf} = PatchWorkflow.approve(wf, "apr_001")

      assert {:ok, wf} = PatchWorkflow.take_checkpoint(wf, "cp_001")
      assert wf.checkpoint_id == "cp_001"
      assert wf.status == :approved
    end

    test "rejects when not approved" do
      {:ok, wf} = PatchWorkflow.new(@valid_attrs)

      assert {:error, {:invalid_transition, :take_checkpoint, :pending_approval}} =
               PatchWorkflow.take_checkpoint(wf, "cp_001")
    end

    test "rejects empty checkpoint_id" do
      {:ok, wf} = PatchWorkflow.new(@valid_attrs)
      {:ok, wf} = PatchWorkflow.approve(wf, "apr_001")

      assert {:error, _} = PatchWorkflow.take_checkpoint(wf, "")
    end
  end

  # -- begin_patching/1 ---------------------------------------------------

  describe "begin_patching/1" do
    test "transitions from approved (with checkpoint) to patching" do
      {:ok, wf} = PatchWorkflow.new(@valid_attrs)
      {:ok, wf} = PatchWorkflow.approve(wf, "apr_001")
      {:ok, wf} = PatchWorkflow.take_checkpoint(wf, "cp_001")

      assert {:ok, wf} = PatchWorkflow.begin_patching(wf)
      assert wf.status == :patching
    end

    test "rejects when checkpoint is missing" do
      {:ok, wf} = PatchWorkflow.new(@valid_attrs)
      {:ok, wf} = PatchWorkflow.approve(wf, "apr_001")

      assert {:error, :checkpoint_required_before_patching} =
               PatchWorkflow.begin_patching(wf)
    end

    test "rejects from non-approved status" do
      {:ok, wf} = PatchWorkflow.new(@valid_attrs)

      assert {:error, {:invalid_transition, :begin_patching, :pending_approval}} =
               PatchWorkflow.begin_patching(wf)
    end
  end

  # -- record_patch/2 -----------------------------------------------------

  describe "record_patch/2" do
    setup do
      {:ok, wf} = PatchWorkflow.new(@valid_attrs)
      {:ok, wf} = PatchWorkflow.approve(wf, "apr_001")
      {:ok, wf} = PatchWorkflow.take_checkpoint(wf, "cp_001")
      {:ok, wf} = PatchWorkflow.begin_patching(wf)
      %{wf: wf}
    end

    test "appends patch result while patching", %{wf: wf} do
      patch = %{file: "lib/parser.ex", status: :applied}

      assert {:ok, wf} = PatchWorkflow.record_patch(wf, patch)
      assert wf.patches_applied == [patch]
    end

    test "accumulates multiple patches", %{wf: wf} do
      p1 = %{file: "lib/a.ex", status: :applied}
      p2 = %{file: "lib/b.ex", status: :applied}

      {:ok, wf} = PatchWorkflow.record_patch(wf, p1)
      {:ok, wf} = PatchWorkflow.record_patch(wf, p2)

      assert wf.patches_applied == [p1, p2]
    end

    test "rejects when not patching" do
      {:ok, wf} = PatchWorkflow.new(@valid_attrs)

      assert {:error, {:invalid_transition, :record_patch, :pending_approval}} =
               PatchWorkflow.record_patch(wf, %{file: "x.ex"})
    end
  end

  # -- succeed/1 -----------------------------------------------------------

  describe "succeed/1" do
    test "marks patching workflow as succeeded" do
      {:ok, wf} = PatchWorkflow.new(@valid_attrs)
      {:ok, wf} = PatchWorkflow.approve(wf, "apr_001")
      {:ok, wf} = PatchWorkflow.take_checkpoint(wf, "cp_001")
      {:ok, wf} = PatchWorkflow.begin_patching(wf)

      assert {:ok, wf} = PatchWorkflow.succeed(wf)
      assert wf.status == :succeeded
      assert %DateTime{} = wf.completed_at
    end

    test "rejects from non-patching status" do
      {:ok, wf} = PatchWorkflow.new(@valid_attrs)

      assert {:error, {:invalid_transition, :succeed, :pending_approval}} =
               PatchWorkflow.succeed(wf)
    end
  end

  # -- fail/2 --------------------------------------------------------------

  describe "fail/2" do
    test "marks patching workflow as failed" do
      {:ok, wf} = PatchWorkflow.new(@valid_attrs)
      {:ok, wf} = PatchWorkflow.approve(wf, "apr_001")
      {:ok, wf} = PatchWorkflow.take_checkpoint(wf, "cp_001")
      {:ok, wf} = PatchWorkflow.begin_patching(wf)

      assert {:ok, wf} = PatchWorkflow.fail(wf, "compilation error")
      assert wf.status == :failed
      assert %DateTime{} = wf.completed_at
    end

    test "rejects from non-patching status" do
      {:ok, wf} = PatchWorkflow.new(@valid_attrs)

      assert {:error, {:invalid_transition, :fail, :pending_approval}} =
               PatchWorkflow.fail(wf, "oops")
    end
  end

  # -- rollback/1 ----------------------------------------------------------

  describe "rollback/1" do
    test "rolls back a failed workflow" do
      {:ok, wf} = PatchWorkflow.new(@valid_attrs)
      {:ok, wf} = PatchWorkflow.approve(wf, "apr_001")
      {:ok, wf} = PatchWorkflow.take_checkpoint(wf, "cp_001")
      {:ok, wf} = PatchWorkflow.begin_patching(wf)
      {:ok, wf} = PatchWorkflow.fail(wf, "broke")

      assert {:ok, wf} = PatchWorkflow.rollback(wf)
      assert wf.status == :rolled_back
    end

    test "rolls back a succeeded workflow (post-hoc)" do
      {:ok, wf} = PatchWorkflow.new(@valid_attrs)
      {:ok, wf} = PatchWorkflow.approve(wf, "apr_001")
      {:ok, wf} = PatchWorkflow.take_checkpoint(wf, "cp_001")
      {:ok, wf} = PatchWorkflow.begin_patching(wf)
      {:ok, wf} = PatchWorkflow.succeed(wf)

      assert {:ok, wf} = PatchWorkflow.rollback(wf)
      assert wf.status == :rolled_back
    end

    test "rejects from pending_approval" do
      {:ok, wf} = PatchWorkflow.new(@valid_attrs)

      assert {:error, {:invalid_transition, :rollback, :pending_approval}} =
               PatchWorkflow.rollback(wf)
    end

    test "rejects from patching (must fail first)" do
      {:ok, wf} = PatchWorkflow.new(@valid_attrs)
      {:ok, wf} = PatchWorkflow.approve(wf, "apr_001")
      {:ok, wf} = PatchWorkflow.take_checkpoint(wf, "cp_001")
      {:ok, wf} = PatchWorkflow.begin_patching(wf)

      assert {:error, {:invalid_transition, :rollback, :patching}} =
               PatchWorkflow.rollback(wf)
    end
  end

  # -- Full lifecycle -------------------------------------------------------

  describe "full lifecycle" do
    test "happy path: pending → approved → patching → succeeded" do
      {:ok, wf} = PatchWorkflow.new(@valid_attrs)
      assert wf.status == :pending_approval

      {:ok, wf} = PatchWorkflow.request_approval(wf, "apr_001")
      assert wf.approval_id == "apr_001"

      {:ok, wf} = PatchWorkflow.approve(wf, "apr_001")
      assert wf.status == :approved

      {:ok, wf} = PatchWorkflow.take_checkpoint(wf, "cp_001")
      assert wf.checkpoint_id == "cp_001"

      {:ok, wf} = PatchWorkflow.begin_patching(wf)
      assert wf.status == :patching

      {:ok, wf} = PatchWorkflow.record_patch(wf, %{file: "lib/parser.ex", status: :applied})
      assert length(wf.patches_applied) == 1

      {:ok, wf} = PatchWorkflow.succeed(wf)
      assert wf.status == :succeeded
      assert %DateTime{} = wf.completed_at
    end

    test "failure path: pending → approved → patching → failed → rolled_back" do
      {:ok, wf} = PatchWorkflow.new(@valid_attrs)
      {:ok, wf} = PatchWorkflow.approve(wf, "apr_001")
      {:ok, wf} = PatchWorkflow.take_checkpoint(wf, "cp_001")
      {:ok, wf} = PatchWorkflow.begin_patching(wf)
      {:ok, wf} = PatchWorkflow.fail(wf, "compilation error")
      {:ok, wf} = PatchWorkflow.rollback(wf)

      assert wf.status == :rolled_back
    end

    test "rejection path: pending → rejected" do
      {:ok, wf} = PatchWorkflow.new(@valid_attrs)
      {:ok, wf} = PatchWorkflow.reject(wf)

      assert wf.status == :rejected
      assert %DateTime{} = wf.completed_at
    end
  end

  # -- statuses/0 and terminal_statuses/0 -----------------------------------

  describe "statuses/0" do
    test "returns all valid statuses" do
      assert PatchWorkflow.statuses() == [
               :pending_approval,
               :approved,
               :patching,
               :succeeded,
               :failed,
               :rejected,
               :rolled_back
             ]
    end
  end

  describe "terminal_statuses/0" do
    test "returns terminal statuses" do
      assert PatchWorkflow.terminal_statuses() == [
               :succeeded,
               :failed,
               :rejected,
               :rolled_back
             ]
    end
  end
end
