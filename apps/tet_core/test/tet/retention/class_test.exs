defmodule Tet.Retention.ClassTest do
  use ExUnit.Case, async: true

  alias Tet.Retention.Class

  describe "classes/0" do
    test "returns all four retention classes" do
      assert Class.classes() == [:transient, :normal, :audit_critical, :permanent]
    end
  end

  describe "default/1" do
    test "transient has 24h TTL and 1000 max count" do
      c = Class.default(:transient)
      assert c.ttl_seconds == 86_400
      assert c.max_count == 1_000
      assert c.audit_protected? == false
    end

    test "normal has 30-day TTL and 10_000 max count" do
      c = Class.default(:normal)
      assert c.ttl_seconds == 2_592_000
      assert c.max_count == 10_000
      assert c.audit_protected? == false
    end

    test "audit_critical has 1-year TTL, no max count, and is protected" do
      c = Class.default(:audit_critical)
      assert c.ttl_seconds == 31_536_000
      assert c.max_count == nil
      assert c.audit_protected? == true
    end

    test "permanent has no TTL, no max count, and is protected" do
      c = Class.default(:permanent)
      assert c.ttl_seconds == nil
      assert c.max_count == nil
      assert c.audit_protected? == true
    end
  end

  describe "new/2" do
    test "creates a class with defaults and overrides" do
      {:ok, c} = Class.new(:transient, ttl_seconds: 3600, max_count: 100)
      assert c.name == :transient
      assert c.ttl_seconds == 3600
      assert c.max_count == 100
      assert c.audit_protected? == false
    end

    test "returns error for unknown class" do
      assert Class.new(:unknown_class) == {:error, :unknown_retention_class}
    end

    test "accepts partial overrides, filling in defaults" do
      {:ok, c} = Class.new(:audit_critical, ttl_seconds: 63_072_000)
      assert c.ttl_seconds == 63_072_000
      assert c.max_count == nil
      assert c.audit_protected? == true
    end

    test "ignores unknown override keys" do
      {:ok, c} = Class.new(:normal, unknown_key: :oops)
      assert c.name == :normal
      assert c.ttl_seconds == 2_592_000
    end
  end

  describe "audit_protected?/1" do
    test "returns true for audit_critical" do
      assert Class.audit_protected?(Class.default(:audit_critical))
    end

    test "returns true for permanent" do
      assert Class.audit_protected?(Class.default(:permanent))
    end

    test "returns false for transient" do
      refute Class.audit_protected?(Class.default(:transient))
    end

    test "returns false for normal" do
      refute Class.audit_protected?(Class.default(:normal))
    end
  end

  describe "finite_ttl?/1" do
    test "returns false for permanent" do
      refute Class.finite_ttl?(Class.default(:permanent))
    end

    test "returns true for transient" do
      assert Class.finite_ttl?(Class.default(:transient))
    end
  end

  describe "bounded_count?/1" do
    test "returns false for audit_critical (nil max_count)" do
      refute Class.bounded_count?(Class.default(:audit_critical))
    end

    test "returns true for transient" do
      assert Class.bounded_count?(Class.default(:transient))
    end
  end
end
