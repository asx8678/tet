defmodule Tet.Mcp.PermissionGateTest do
  use ExUnit.Case, async: true

  alias Tet.Mcp.CallPolicy
  alias Tet.Mcp.PermissionGate

  describe "check/3" do
    test "allows read in any task context with default policy" do
      policy = CallPolicy.default()

      for task <- [:researching, :planning, :acting, :debugging, :documenting] do
        assert PermissionGate.check(:read, %{task_category: task}, policy) == {:ok, :allow}
      end
    end

    test "denies blocked categories regardless of task" do
      policy =
        CallPolicy.new!(%{
          allowed_categories: [:read],
          require_approval: [],
          blocked_categories: [:shell, :admin]
        })

      assert PermissionGate.check(:shell, %{task_category: :acting}, policy) == {:ok, :deny}
      assert PermissionGate.check(:admin, %{task_category: :acting}, policy) == {:ok, :deny}
    end

    test "requires approval for write with default policy" do
      policy = CallPolicy.default()

      assert PermissionGate.check(:write, %{task_category: :acting}, policy) ==
               {:ok, {:needs_approval, :policy_requires_approval}}
    end

    test "requires approval for shell with default policy" do
      policy = CallPolicy.default()

      assert PermissionGate.check(:shell, %{task_category: :acting}, policy) ==
               {:ok, {:needs_approval, :policy_requires_approval}}
    end

    test "requires approval for network with default policy" do
      policy = CallPolicy.default()

      assert PermissionGate.check(:network, %{task_category: :acting}, policy) ==
               {:ok, {:needs_approval, :policy_requires_approval}}
    end

    test "allows write when explicitly allowed in policy and task context permits" do
      policy =
        CallPolicy.new!(%{
          allowed_categories: [:read, :write],
          require_approval: [:shell, :network, :admin]
        })

      assert PermissionGate.check(:write, %{task_category: :acting}, policy) == {:ok, :allow}
    end

    test "downgrades to needs_approval when task context restricts write" do
      policy =
        CallPolicy.new!(%{
          allowed_categories: [:read, :write],
          require_approval: [:shell, :network, :admin]
        })

      # Policy allows write, but researching task context doesn't
      assert PermissionGate.check(:write, %{task_category: :researching}, policy) ==
               {:ok, {:needs_approval, :task_context_restriction}}
    end

    test "blocked takes precedence over allowed" do
      policy =
        CallPolicy.new!(%{
          allowed_categories: [:read, :write],
          require_approval: [:network],
          blocked_categories: [:shell, :admin]
        })

      assert PermissionGate.check(:shell, %{task_category: :acting}, policy) == {:ok, :deny}
      assert PermissionGate.check(:admin, %{task_category: :acting}, policy) == {:ok, :deny}
    end

    test "unknown categories fail-closed to needs_approval" do
      policy = CallPolicy.default()

      assert PermissionGate.check(:foobar, %{task_category: :acting}, policy) ==
               {:ok, {:needs_approval, :category_not_allowed}}
    end

    test "task_defaults policy for researching blocks shell and admin" do
      policy = CallPolicy.task_defaults().researching

      assert PermissionGate.check(:shell, %{task_category: :researching}, policy) == {:ok, :deny}
      assert PermissionGate.check(:admin, %{task_category: :researching}, policy) == {:ok, :deny}
    end

    test "task_defaults policy for acting allows write" do
      policy = CallPolicy.task_defaults().acting

      assert PermissionGate.check(:write, %{task_category: :acting}, policy) == {:ok, :allow}
    end
  end

  describe "approve/2" do
    test "approves a valid approval ref" do
      assert PermissionGate.approve({"call-1", :write}, %{task_category: :acting}) == :ok
      assert PermissionGate.approve({"call-2", :shell}, %{task_category: :acting}) == :ok
    end

    test "rejects invalid category in ref" do
      assert PermissionGate.approve({"call-1", :invalid}, %{}) ==
               {:error, {:invalid_category, :invalid}}
    end

    test "rejects non-binary call_id" do
      assert PermissionGate.approve({123, :write}, %{}) == {:error, :invalid_approval_ref}
    end
  end

  describe "deny/2" do
    test "always returns :ok" do
      assert PermissionGate.deny({"call-1", :shell}, :user_denied) == :ok
      assert PermissionGate.deny({"call-2", :write}, :timeout) == :ok
    end
  end

  describe "safe_for_task?/2" do
    test "read is always safe" do
      assert PermissionGate.safe_for_task?(:read, %{task_category: :researching}) == true
      assert PermissionGate.safe_for_task?(:read, %{task_category: :acting}) == true
      assert PermissionGate.safe_for_task?(:read, %{task_category: :planning}) == true
    end

    test "shell is never safe without approval" do
      assert PermissionGate.safe_for_task?(:shell, %{task_category: :acting}) == false
      assert PermissionGate.safe_for_task?(:shell, %{task_category: :debugging}) == false
      assert PermissionGate.safe_for_task?(:shell, %{task_category: :researching}) == false
    end

    test "admin is never safe without approval" do
      assert PermissionGate.safe_for_task?(:admin, %{task_category: :acting}) == false
      assert PermissionGate.safe_for_task?(:admin, %{task_category: :debugging}) == false
    end

    test "write is safe only in acting/debugging" do
      assert PermissionGate.safe_for_task?(:write, %{task_category: :acting}) == true
      assert PermissionGate.safe_for_task?(:write, %{task_category: :debugging}) == true
      assert PermissionGate.safe_for_task?(:write, %{task_category: :researching}) == false
      assert PermissionGate.safe_for_task?(:write, %{task_category: :planning}) == false
    end

    test "network is safe only in acting" do
      assert PermissionGate.safe_for_task?(:network, %{task_category: :acting}) == true
      assert PermissionGate.safe_for_task?(:network, %{task_category: :debugging}) == false
      assert PermissionGate.safe_for_task?(:network, %{task_category: :researching}) == false
    end
  end
end
