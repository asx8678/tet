defmodule Tet.Retention.PolicyTest do
  use ExUnit.Case, async: true

  alias Tet.Retention.{Class, Policy}

  describe "new/1" do
    test "builds a policy with all defaults" do
      {:ok, policy} = Policy.new([])

      assert Map.has_key?(policy.classes, :transient)
      assert Map.has_key?(policy.classes, :normal)
      assert Map.has_key?(policy.classes, :audit_critical)
      assert Map.has_key?(policy.classes, :permanent)

      assert policy.data_type_map.event_log == :audit_critical
      assert policy.data_type_map.approval == :permanent
      assert policy.data_type_map.checkpoint == :transient
      assert policy.data_type_map.artifact == :normal
      assert policy.data_type_map.error_log == :audit_critical
      assert policy.data_type_map.repair == :audit_critical
      assert policy.data_type_map.workflow == :audit_critical
      assert policy.data_type_map.workflow_step == :audit_critical
    end

    test "accepts class overrides" do
      {:ok, policy} =
        Policy.new(
          classes: [
            transient: [ttl_seconds: 3600, max_count: 50],
            audit_critical: [ttl_seconds: 63_072_000]
          ]
        )

      assert policy.classes.transient.ttl_seconds == 3600
      assert policy.classes.transient.max_count == 50
      assert policy.classes.audit_critical.ttl_seconds == 63_072_000
      # unchanged default
      assert policy.classes.normal.ttl_seconds == 2_592_000
    end

    test "accepts data type overrides" do
      {:ok, policy} = Policy.new(overrides: [checkpoint: :normal, artifact: :audit_critical])
      assert policy.data_type_map.checkpoint == :normal
      assert policy.data_type_map.artifact == :audit_critical
      # unchanged
      assert policy.data_type_map.event_log == :audit_critical
    end
  end

  describe "load/0" do
    test "returns default policy when no config is set" do
      policy = Policy.load()
      assert policy.classes.transient.ttl_seconds == 86_400
      assert policy.data_type_map.checkpoint == :transient
    end
  end

  describe "class_for/2" do
    test "returns the class for a data type" do
      {:ok, policy} = Policy.new([])
      assert %Class{name: :transient} = Policy.class_for(policy, :checkpoint)
      assert %Class{name: :audit_critical} = Policy.class_for(policy, :event_log)
      assert %Class{name: :permanent} = Policy.class_for(policy, :approval)
    end

    test "raises for unknown data type" do
      {:ok, policy} = Policy.new([])

      assert_raise ArgumentError, fn ->
        Policy.class_for(policy, :nonexistent_type)
      end
    end
  end

  describe "audit_protected?/2" do
    test "returns true for audit_critical data types" do
      {:ok, policy} = Policy.new([])
      assert Policy.audit_protected?(policy, :event_log)
      assert Policy.audit_protected?(policy, :error_log)
      assert Policy.audit_protected?(policy, :repair)
      assert Policy.audit_protected?(policy, :workflow)
      assert Policy.audit_protected?(policy, :workflow_step)
    end

    test "returns true for permanent data types" do
      {:ok, policy} = Policy.new([])
      assert Policy.audit_protected?(policy, :approval)
    end

    test "returns false for transient and normal data types" do
      {:ok, policy} = Policy.new([])
      refute Policy.audit_protected?(policy, :checkpoint)
      refute Policy.audit_protected?(policy, :artifact)
    end
  end

  describe "deletable?/2" do
    test "returns true for data types with finite TTL or bounded count" do
      {:ok, policy} = Policy.new([])
      assert Policy.deletable?(policy, :checkpoint)
      assert Policy.deletable?(policy, :artifact)
    end

    test "returns false for permanent data types" do
      {:ok, policy} = Policy.new([])
      refute Policy.deletable?(policy, :approval)
    end
  end

  describe "ttl_seconds/2" do
    test "returns TTL for a data type" do
      {:ok, policy} = Policy.new([])
      assert Policy.ttl_seconds(policy, :checkpoint) == 86_400
    end

    test "returns nil for permanent data types" do
      {:ok, policy} = Policy.new([])
      assert Policy.ttl_seconds(policy, :approval) == nil
    end
  end

  describe "max_count/2" do
    test "returns max count for a data type" do
      {:ok, policy} = Policy.new([])
      assert Policy.max_count(policy, :checkpoint) == 1_000
    end

    test "returns nil for unlimited data types" do
      {:ok, policy} = Policy.new([])
      assert Policy.max_count(policy, :event_log) == nil
    end
  end

  describe "generate_ack_token/4" do
    test "generates a base64-encoded HMAC token" do
      {:ok, policy} = Policy.new([])
      token = Policy.generate_ack_token(policy, :error_log, "err_001")

      assert is_binary(token)
      # Token should be URL-safe base64 (no padding issues)
      assert String.match?(token, ~r/^[A-Za-z0-9\-_]+$/)
    end

    test "different record IDs produce different tokens" do
      {:ok, policy} = Policy.new([])
      t1 = Policy.generate_ack_token(policy, :error_log, "err_001")
      t2 = Policy.generate_ack_token(policy, :error_log, "err_002")
      assert t1 != t2
    end

    test "tokens include nonce so they are non-deterministic" do
      {:ok, policy} = Policy.new([])
      t1 = Policy.generate_ack_token(policy, :error_log, "err_001")
      t2 = Policy.generate_ack_token(policy, :error_log, "err_001")
      # Same inputs but different nonces → different tokens
      assert t1 != t2
    end

    test "honors actor option" do
      {:ok, policy} = Policy.new([])
      t1 = Policy.generate_ack_token(policy, :error_log, "err_001", actor: "ops")
      t2 = Policy.generate_ack_token(policy, :error_log, "err_001", actor: "different_ops")
      assert t1 != t2
    end
  end

  describe "safety invariants" do
    test "prevents overriding audit_critical class to be unprotected" do
      assert {:error, {:class_must_be_audit_protected, :audit_critical}} =
               Policy.new(classes: [audit_critical: [audit_protected?: false]])
    end

    test "prevents overriding permanent class to be unprotected" do
      assert {:error, {:class_must_be_audit_protected, :permanent}} =
               Policy.new(classes: [permanent: [audit_protected?: false]])
    end

    test "prevents remapping audit-critical data type to unprotected class" do
      assert {:error, {:cannot_unprotect_audit_critical_type, :event_log}} =
               Policy.new(overrides: [event_log: :normal])

      assert {:error, {:cannot_unprotect_audit_critical_type, :approval}} =
               Policy.new(overrides: [approval: :normal])

      assert {:error, {:cannot_unprotect_audit_critical_type, :error_log}} =
               Policy.new(overrides: [error_log: :transient])
    end

    test "allows remapping audit-critical type to another protected class" do
      {:ok, policy} = Policy.new(overrides: [event_log: :permanent])
      assert Policy.audit_protected?(policy, :event_log)
    end

    test "allows remapping non-critical types freely" do
      {:ok, policy} = Policy.new(overrides: [checkpoint: :normal, artifact: :transient])
      assert policy.data_type_map.checkpoint == :normal
      assert policy.data_type_map.artifact == :transient
    end
  end
end
