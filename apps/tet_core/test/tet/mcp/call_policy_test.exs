defmodule Tet.Mcp.CallPolicyTest do
  use ExUnit.Case, async: true

  alias Tet.Mcp.CallPolicy

  describe "new/1" do
    test "creates default policy" do
      {:ok, policy} = CallPolicy.new(%{})

      assert policy.allowed_categories == [:read]
      assert policy.require_approval == [:write, :shell, :network, :admin]
      assert policy.blocked_categories == []
    end

    test "creates policy with custom allowed categories" do
      {:ok, policy} =
        CallPolicy.new(%{
          allowed_categories: [:read, :write],
          require_approval: [:shell, :network, :admin]
        })

      assert policy.allowed_categories == [:read, :write]
    end

    test "creates policy with custom blocked categories" do
      {:ok, policy} =
        CallPolicy.new(%{
          allowed_categories: [:read],
          blocked_categories: [:shell, :admin]
        })

      assert policy.blocked_categories == [:shell, :admin]
    end

    test "rejects overlap between allowed and blocked" do
      assert {:error, {:policy_category_overlap, [:read]}} =
               CallPolicy.new(%{
                 allowed_categories: [:read, :write],
                 blocked_categories: [:read]
               })
    end

    test "rejects overlap between allowed and require_approval" do
      assert {:error, {:allowed_require_approval_overlap, [:write]}} =
               CallPolicy.new(%{
                 allowed_categories: [:read, :write],
                 require_approval: [:write, :shell]
               })
    end

    test "rejects invalid category in allowed_categories" do
      assert {:error, {:invalid_categories, :allowed_categories}} =
               CallPolicy.new(%{allowed_categories: [:read, :bogus]})
    end

    test "rejects invalid category in require_approval" do
      assert {:error, {:invalid_categories, :require_approval}} =
               CallPolicy.new(%{require_approval: [:write, :nope]})
    end

    test "rejects non-map input" do
      assert CallPolicy.new("bad") == {:error, :invalid_call_policy}
    end
  end

  describe "new!/1" do
    test "returns policy on success" do
      policy = CallPolicy.new!(%{})
      assert policy.allowed_categories == [:read]
    end

    test "raises on invalid input" do
      assert_raise ArgumentError, ~r/invalid call policy/, fn ->
        CallPolicy.new!(%{allowed_categories: [:bogus]})
      end
    end
  end

  describe "default/0" do
    test "returns read-only default policy" do
      policy = CallPolicy.default()
      assert policy.allowed_categories == [:read]
      assert :shell in policy.require_approval
    end
  end

  describe "evaluate/2" do
    test "allows read with default policy" do
      assert CallPolicy.evaluate(:read, CallPolicy.default()) == {:ok, :allow}
    end

    test "denies blocked categories" do
      policy =
        CallPolicy.new!(%{
          allowed_categories: [:read],
          blocked_categories: [:shell]
        })

      assert CallPolicy.evaluate(:shell, policy) == {:ok, :deny}
    end

    test "requires approval for write with default policy" do
      assert CallPolicy.evaluate(:write, CallPolicy.default()) ==
               {:ok, {:needs_approval, :policy_requires_approval}}
    end

    test "requires approval for shell with default policy" do
      assert CallPolicy.evaluate(:shell, CallPolicy.default()) ==
               {:ok, {:needs_approval, :policy_requires_approval}}
    end

    test "requires approval for network with default policy" do
      assert CallPolicy.evaluate(:network, CallPolicy.default()) ==
               {:ok, {:needs_approval, :policy_requires_approval}}
    end

    test "requires approval for admin with default policy" do
      assert CallPolicy.evaluate(:admin, CallPolicy.default()) ==
               {:ok, {:needs_approval, :policy_requires_approval}}
    end

    test "unknown category fail-closes to needs_approval" do
      assert CallPolicy.evaluate(:foobar, CallPolicy.default()) ==
               {:ok, {:needs_approval, :category_not_allowed}}
    end

    test "blocked takes precedence over allowed (via valid policy)" do
      policy =
        CallPolicy.new!(%{
          allowed_categories: [:read],
          require_approval: [],
          blocked_categories: [:shell]
        })

      assert CallPolicy.evaluate(:shell, policy) == {:ok, :deny}
    end

    test "require_approval takes precedence over allowed_categories" do
      # Even if a category were in both (which validation now prevents),
      # require_approval is checked before allowed_categories.
      # We test this with a valid policy where a category is only in require_approval.
      policy =
        CallPolicy.new!(%{
          allowed_categories: [:read],
          require_approval: [:write],
          blocked_categories: []
        })

      assert CallPolicy.evaluate(:write, policy) ==
               {:ok, {:needs_approval, :policy_requires_approval}}
    end

    test "permissive policy allows all but admin" do
      policy =
        CallPolicy.new!(%{
          allowed_categories: [:read, :write, :shell, :network],
          require_approval: [:admin],
          blocked_categories: []
        })

      assert CallPolicy.evaluate(:read, policy) == {:ok, :allow}
      assert CallPolicy.evaluate(:write, policy) == {:ok, :allow}
      assert CallPolicy.evaluate(:shell, policy) == {:ok, :allow}
      assert CallPolicy.evaluate(:network, policy) == {:ok, :allow}

      assert CallPolicy.evaluate(:admin, policy) ==
               {:ok, {:needs_approval, :policy_requires_approval}}
    end
  end

  describe "task_defaults/0" do
    test "returns a map with all six task types" do
      defaults = CallPolicy.task_defaults()

      for task_type <- [:researching, :planning, :acting, :verifying, :debugging, :documenting] do
        assert Map.has_key?(defaults, task_type), "missing task type: #{task_type}"
      end
    end

    test "researching only allows read" do
      policy = CallPolicy.task_defaults().researching
      assert policy.allowed_categories == [:read]
      assert :shell in policy.blocked_categories
      assert :admin in policy.blocked_categories
    end

    test "acting allows read and write" do
      policy = CallPolicy.task_defaults().acting
      assert :read in policy.allowed_categories
      assert :write in policy.allowed_categories
      assert :shell in policy.require_approval
    end

    test "debugging allows read and write" do
      policy = CallPolicy.task_defaults().debugging
      assert :read in policy.allowed_categories
      assert :write in policy.allowed_categories
    end

    test "no task type gets shell by default" do
      for {_task, policy} <- CallPolicy.task_defaults() do
        refute :shell in policy.allowed_categories,
               "shell should not be in allowed_categories by default"
      end
    end

    test "no task type gets admin by default" do
      for {_task, policy} <- CallPolicy.task_defaults() do
        refute :admin in policy.allowed_categories,
               "admin should not be in allowed_categories by default"
      end
    end
  end
end
