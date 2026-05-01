defmodule Tet.Approval.ApprovalTest do
  @moduledoc """
  BD-0027: Approval row struct tests.

  Covers construction, validation, status lifecycle, transitions,
  serialization round-trips, and correlation metadata.
  """

  use ExUnit.Case, async: true

  alias Tet.Approval.Approval

  describe "new/1" do
    test "builds a valid approval from required attrs" do
      attrs = %{
        id: "appr_001",
        tool_call_id: "call_abc123",
        status: :pending
      }

      assert {:ok, approval} = Approval.new(attrs)
      assert approval.id == "appr_001"
      assert approval.tool_call_id == "call_abc123"
      assert approval.status == :pending
      assert approval.approver == nil
      assert approval.rationale == nil
      assert approval.metadata == %{}
    end

    test "builds approval with all optional attrs" do
      now = DateTime.utc_now()

      attrs = %{
        id: "appr_002",
        tool_call_id: "call_xyz",
        status: :approved,
        approver: "adam",
        rationale: "Looks good to me",
        created_at: now,
        approved_at: now,
        session_id: "ses_001",
        task_id: "task_001",
        metadata: %{tool_name: "write-file"}
      }

      assert {:ok, approval} = Approval.new(attrs)
      assert approval.approver == "adam"
      assert approval.rationale == "Looks good to me"
      assert approval.session_id == "ses_001"
      assert approval.task_id == "task_001"
    end

    test "defaults status to pending when omitted" do
      attrs = %{id: "appr_003", tool_call_id: "call_def"}

      assert {:ok, approval} = Approval.new(attrs)
      assert approval.status == :pending
    end

    test "accepts string status via parsing" do
      attrs = %{id: "appr_004", tool_call_id: "call_ghi", status: "pending"}

      assert {:ok, approval} = Approval.new(attrs)
      assert approval.status == :pending
    end

    test "rejects missing id" do
      assert {:error, {:invalid_approval_field, :id}} = Approval.new(%{tool_call_id: "call_1"})
    end

    test "rejects empty id" do
      assert {:error, {:invalid_approval_field, :id}} =
               Approval.new(%{id: "", tool_call_id: "call_1"})
    end

    test "rejects missing tool_call_id" do
      assert {:error, {:invalid_approval_field, :tool_call_id}} = Approval.new(%{id: "appr_1"})
    end

    test "rejects invalid status" do
      assert {:error, {:invalid_approval_field, :status}} =
               Approval.new(%{id: "appr_1", tool_call_id: "call_1", status: :unknown})
    end

    test "rejects pending approval with approved_at timestamp" do
      now = DateTime.utc_now()

      assert {:error, {:pending_approval_has_terminal_timestamp, nil}} =
               Approval.new(%{
                 id: "appr_1",
                 tool_call_id: "call_1",
                 status: :pending,
                 approved_at: now
               })
    end

    test "rejects approved status without approved_at" do
      assert {:error, {:invalid_approval_field, :approved_at}} =
               Approval.new(%{id: "appr_1", tool_call_id: "call_1", status: :approved})
    end

    test "rejects rejected status without rejected_at" do
      assert {:error, {:invalid_approval_field, :rejected_at}} =
               Approval.new(%{id: "appr_1", tool_call_id: "call_1", status: :rejected})
    end

    test "accepts string-keyed attrs" do
      attrs = %{"id" => "appr_s", "tool_call_id" => "call_s", "status" => "pending"}

      assert {:ok, approval} = Approval.new(attrs)
      assert approval.id == "appr_s"
    end

    test "accepts ISO8601 timestamp strings" do
      attrs = %{
        id: "appr_ts",
        tool_call_id: "call_ts",
        status: :approved,
        approved_at: "2025-05-01T12:00:00Z"
      }

      assert {:ok, approval} = Approval.new(attrs)
      assert approval.approved_at == ~U[2025-05-01 12:00:00Z]
    end
  end

  describe "new!/1" do
    test "builds or raises" do
      attrs = %{id: "appr_1", tool_call_id: "call_1"}

      assert %Approval{} = Approval.new!(attrs)
    end

    test "raises on invalid attrs" do
      assert_raise ArgumentError, fn ->
        Approval.new!(%{id: ""})
      end
    end
  end

  describe "statuses/0" do
    test "returns all valid statuses" do
      assert :pending in Approval.statuses()
      assert :approved in Approval.statuses()
      assert :rejected in Approval.statuses()
    end
  end

  describe "terminal?/1" do
    test "approved is terminal" do
      assert Approval.terminal?(:approved)
    end

    test "rejected is terminal" do
      assert Approval.terminal?(:rejected)
    end

    test "pending is not terminal" do
      refute Approval.terminal?(:pending)
    end
  end

  describe "transition/2" do
    test "pending → approved" do
      approval = Approval.new!(%{id: "a1", tool_call_id: "c1"})
      assert {:ok, updated} = Approval.transition(approval, :approved)
      assert updated.status == :approved
    end

    test "pending → rejected" do
      approval = Approval.new!(%{id: "a1", tool_call_id: "c1"})
      assert {:ok, updated} = Approval.transition(approval, :rejected)
      assert updated.status == :rejected
    end

    test "rejects approved → pending" do
      approval = %Approval{id: "a1", tool_call_id: "c1", status: :approved}

      assert {:error, {:invalid_approval_transition, :approved, :pending}} =
               Approval.transition(approval, :pending)
    end

    test "rejects rejected → approved" do
      approval = %Approval{id: "a1", tool_call_id: "c1", status: :rejected}

      assert {:error, {:invalid_approval_transition, :rejected, :approved}} =
               Approval.transition(approval, :approved)
    end

    test "rejects approved → approved (no-op)" do
      approval = %Approval{id: "a1", tool_call_id: "c1", status: :approved}
      assert {:error, _} = Approval.transition(approval, :approved)
    end

    test "rejects invalid target status" do
      approval = Approval.new!(%{id: "a1", tool_call_id: "c1"})
      assert {:error, _} = Approval.transition(approval, :unknown)
    end
  end

  describe "approve/3" do
    test "approves a pending approval with approver and rationale" do
      approval =
        Approval.new!(%{id: "a1", tool_call_id: "c1", session_id: "ses_1", task_id: "t1"})

      assert {:ok, updated} = Approval.approve(approval, "adam", "Looks safe")
      assert updated.status == :approved
      assert updated.approver == "adam"
      assert updated.rationale == "Looks safe"
      refute is_nil(updated.approved_at)
      # Correlation preserved
      assert updated.session_id == "ses_1"
      assert updated.task_id == "t1"
    end

    test "rejects approving a non-pending approval" do
      approval = %Approval{id: "a1", tool_call_id: "c1", status: :approved}
      assert {:error, _} = Approval.approve(approval, "adam", "why not")
    end

    test "rejects non-binary approver" do
      approval = Approval.new!(%{id: "a1", tool_call_id: "c1"})

      assert {:error, {:invalid_approver_or_rationale, nil}} =
               Approval.approve(approval, nil, "ok")
    end
  end

  describe "reject/3" do
    test "rejects a pending approval with approver and rationale" do
      approval = Approval.new!(%{id: "a1", tool_call_id: "c1"})

      assert {:ok, updated} = Approval.reject(approval, "bob", "Too risky")
      assert updated.status == :rejected
      assert updated.approver == "bob"
      assert updated.rationale == "Too risky"
      refute is_nil(updated.rejected_at)
    end

    test "rejects rejecting a non-pending approval" do
      approval = %Approval{id: "a1", tool_call_id: "c1", status: :rejected}
      assert {:error, _} = Approval.reject(approval, "bob", "nope")
    end
  end

  describe "to_map/1 and from_map/1 round-trip" do
    test "round-trips a pending approval" do
      approval =
        Approval.new!(%{
          id: "appr_rt",
          tool_call_id: "call_rt",
          session_id: "ses_rt",
          task_id: "task_rt",
          metadata: %{tool: "write"}
        })

      map = Approval.to_map(approval)
      assert map.id == "appr_rt"
      assert map.tool_call_id == "call_rt"
      assert map.status == "pending"
      assert map.session_id == "ses_rt"

      assert {:ok, restored} = Approval.from_map(map)
      assert restored.id == approval.id
      assert restored.tool_call_id == approval.tool_call_id
      assert restored.status == approval.status
      assert restored.session_id == approval.session_id
      assert restored.task_id == approval.task_id
    end

    test "round-trips an approved approval with timestamps" do
      now_str = "2025-05-01T12:00:00Z"

      approval =
        Approval.new!(%{
          id: "appr_rt2",
          tool_call_id: "call_rt2",
          status: :approved,
          approver: "adam",
          rationale: "OK",
          approved_at: now_str
        })

      map = Approval.to_map(approval)
      assert map.status == "approved"
      assert map.approver == "adam"
      assert map.approved_at == now_str

      assert {:ok, restored} = Approval.from_map(map)
      assert restored.status == :approved
      assert restored.approver == "adam"
    end
  end
end
