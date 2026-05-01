defmodule Tet.Runtime.Mcp.PolicyGateTest do
  use ExUnit.Case, async: false

  alias Tet.Mcp.CallPolicy
  alias Tet.Runtime.Mcp.PolicyGate

  setup do
    # Start a unique PolicyGate per test to avoid name collisions
    name = :"policy_gate_test_#{System.unique_integer([:positive])}"
    {:ok, _pid} = PolicyGate.start_link(name: name, policy: CallPolicy.default())
    {:ok, server: name}
  end

  describe "authorize_call/3" do
    test "allows read-classified tools", %{server: server} do
      {:allow, _call_id} =
        PolicyGate.authorize_call(
          %{name: "read_file"},
          %{task_category: :researching},
          server: server
        )
    end

    test "needs approval for write-classified tools", %{server: server} do
      {:needs_approval, _call_id, :policy_requires_approval} =
        PolicyGate.authorize_call(
          %{name: "write_file"},
          %{task_category: :researching},
          server: server
        )
    end

    test "denies shell-classified tools when policy blocks them", %{server: server} do
      # Default policy has shell in require_approval, not blocked — so it should
      # return needs_approval, not deny. Let's update policy to block shell.
      blocked_policy =
        CallPolicy.new!(%{
          allowed_categories: [:read],
          require_approval: [:write, :network],
          blocked_categories: [:shell, :admin]
        })

      :ok = PolicyGate.update_policy(blocked_policy, server: server)

      {:deny, _call_id, :blocked_by_policy} =
        PolicyGate.authorize_call(
          %{name: "run_bash"},
          %{task_category: :acting},
          server: server
        )
    end

    test "shell needs approval with default policy", %{server: server} do
      {:needs_approval, _call_id, _reason} =
        PolicyGate.authorize_call(
          %{name: "run_bash"},
          %{task_category: :acting},
          server: server
        )
    end
  end

  describe "approve_call/2 and deny_call/2" do
    test "approves a pending call", %{server: server} do
      {:needs_approval, call_id, _reason} =
        PolicyGate.authorize_call(
          %{name: "write_file"},
          %{task_category: :acting},
          server: server
        )

      assert :ok = PolicyGate.approve_call(call_id, server: server)
    end

    test "denies a pending call", %{server: server} do
      {:needs_approval, call_id, _reason} =
        PolicyGate.authorize_call(
          %{name: "write_file"},
          %{task_category: :acting},
          server: server
        )

      assert :ok = PolicyGate.deny_call(call_id, server: server)
    end

    test "approve returns error for unknown call_id", %{server: server} do
      assert {:error, :not_found} = PolicyGate.approve_call("nonexistent", server: server)
    end

    test "deny returns error for unknown call_id", %{server: server} do
      assert {:error, :not_found} = PolicyGate.deny_call("nonexistent", server: server)
    end
  end

  describe "update_policy/2" do
    test "changing policy changes authorization behavior", %{server: server} do
      # Default policy: write needs approval
      {:needs_approval, _call_id, _reason} =
        PolicyGate.authorize_call(
          %{name: "write_file"},
          %{task_category: :acting},
          server: server
        )

      # Update to allow write
      new_policy =
        CallPolicy.new!(%{
          allowed_categories: [:read, :write],
          require_approval: [:shell, :network, :admin],
          blocked_categories: []
        })

      :ok = PolicyGate.update_policy(new_policy, server: server)

      {:allow, _call_id} =
        PolicyGate.authorize_call(
          %{name: "write_file"},
          %{task_category: :acting},
          server: server
        )
    end

    test "get_policy returns current policy", %{server: server} do
      policy = PolicyGate.get_policy(server: server)
      assert policy.allowed_categories == [:read]
    end
  end

  describe "string-keyed MCP descriptors" do
    test "classify correctly with string keys", %{server: server} do
      # String-keyed descriptor should still classify as :read
      {:allow, _call_id} =
        PolicyGate.authorize_call(
          %{"name" => "read_file"},
          %{task_category: :researching},
          server: server
        )

      # String-keyed descriptor should classify as :write → needs approval
      {:needs_approval, _call_id, _reason} =
        PolicyGate.authorize_call(
          %{"name" => "write_file"},
          %{task_category: :researching},
          server: server
        )
    end

    test "string-keyed mcp_category cannot downgrade risk", %{server: server} do
      # run_bash with mcp_category: "read" — heuristic wins → :shell
      {:needs_approval, _call_id, _reason} =
        PolicyGate.authorize_call(
          %{"name" => "run_bash", "mcp_category" => "read"},
          %{task_category: :acting},
          server: server
        )
    end
  end

  describe "list_pending/1" do
    test "returns pending approvals", %{server: server} do
      {:needs_approval, call_id, _reason} =
        PolicyGate.authorize_call(
          %{name: "write_file"},
          %{task_category: :researching},
          server: server
        )

      pending = PolicyGate.list_pending(server: server)
      assert length(pending) == 1
      assert hd(pending).call_id == call_id
    end

    test "empty when no pending approvals", %{server: server} do
      # read_file is allowed, no pending
      PolicyGate.authorize_call(
        %{name: "read_file"},
        %{task_category: :researching},
        server: server
      )

      assert PolicyGate.list_pending(server: server) == []
    end
  end
end
