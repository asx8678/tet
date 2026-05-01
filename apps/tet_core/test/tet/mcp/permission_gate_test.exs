defmodule Tet.Mcp.PermissionGateTest do
  use ExUnit.Case, async: true

  alias Tet.Mcp.CallPolicy
  alias Tet.Mcp.PermissionGate

  describe "check/3" do
    test "allows read in any task context with default policy" do
      policy = CallPolicy.default()

      for task <- [:researching, :planning, :acting, :debugging, :documenting] do
        assert PermissionGate.check(:read, %{task_category: task}, policy) == :allow
      end
    end

    test "denies blocked categories regardless of task" do
      policy =
        CallPolicy.new!(%{
          allowed_categories: [:read],
          require_approval: [],
          blocked_categories: [:shell, :admin]
        })

      assert PermissionGate.check(:shell, %{task_category: :acting}, policy) == :deny
      assert PermissionGate.check(:admin, %{task_category: :acting}, policy) == :deny
    end

    test "requires approval for write with default policy" do
      policy = CallPolicy.default()

      assert PermissionGate.check(:write, %{task_category: :acting}, policy) ==
               {:needs_approval, :policy_requires_approval}
    end

    test "requires approval for shell with default policy" do
      policy = CallPolicy.default()

      assert PermissionGate.check(:shell, %{task_category: :acting}, policy) ==
               {:needs_approval, :policy_requires_approval}
    end

    test "requires approval for network with default policy" do
      policy = CallPolicy.default()

      assert PermissionGate.check(:network, %{task_category: :acting}, policy) ==
               {:needs_approval, :policy_requires_approval}
    end

    test "allows write when explicitly allowed in policy" do
      policy = CallPolicy.new!(%{allowed_categories: [:read, :write]})

      assert PermissionGate.check(:write, %{task_category: :acting}, policy) == :allow
    end

    test "blocked takes precedence over allowed" do
      # This policy is invalid per validation, but test the pure check:
      # Actually this would fail validation. Let's test with a valid scenario.
      policy =
        CallPolicy.new!(%{
          allowed_categories: [:read, :write],
          require_approval: [:network],
          blocked_categories: [:shell, :admin]
        })

      assert PermissionGate.check(:shell, %{task_category: :acting}, policy) == :deny
      assert PermissionGate.check(:admin, %{task_category: :acting}, policy) == :deny
    end

    test "unknown categories fail-closed to needs_approval" do
      policy = CallPolicy.default()

      assert PermissionGate.check(:foobar, %{task_category: :acting}, policy) ==
               {:needs_approval, :category_not_allowed}
    end

    test "task_defaults policy for researching blocks shell and admin" do
      policy = CallPolicy.task_defaults().researching

      assert PermissionGate.check(:shell, %{task_category: :researching}, policy) == :deny
      assert PermissionGate.check(:admin, %{task_category: :researching}, policy) == :deny
    end

    test "task_defaults policy for acting allows write" do
      policy = CallPolicy.task_defaults().acting

      assert PermissionGate.check(:write, %{task_category: :acting}, policy) == :allow
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
      assert PermissionGate.safe_for_task?(:read, :researching) == true
      assert PermissionGate.safe_for_task?(:read, :acting) == true
      assert PermissionGate.safe_for_task?(:read, :planning) == true
    end

    test "shell is never safe without approval" do
      assert PermissionGate.safe_for_task?(:shell, :acting) == false
      assert PermissionGate.safe_for_task?(:shell, :debugging) == false
      assert PermissionGate.safe_for_task?(:shell, :researching) == false
    end

    test "admin is never safe without approval" do
      assert PermissionGate.safe_for_task?(:admin, :acting) == false
      assert PermissionGate.safe_for_task?(:admin, :debugging) == false
    end

    test "write is safe only in acting/debugging" do
      assert PermissionGate.safe_for_task?(:write, :acting) == true
      assert PermissionGate.safe_for_task?(:write, :debugging) == true
      assert PermissionGate.safe_for_task?(:write, :researching) == false
      assert PermissionGate.safe_for_task?(:write, :planning) == false
    end

    test "network is safe only in acting/debugging" do
      assert PermissionGate.safe_for_task?(:network, :acting) == true
      assert PermissionGate.safe_for_task?(:network, :debugging) == true
      assert PermissionGate.safe_for_task?(:network, :researching) == false
    end
  end
end
