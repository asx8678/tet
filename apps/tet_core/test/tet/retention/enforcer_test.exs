defmodule Tet.Retention.EnforcerTest do
  use ExUnit.Case, async: true

  alias Tet.Retention.{Enforcer, Policy}

  setup do
    # Set a known ack_secret for deterministic token generation in tests.
    # Policy.ack_secret/0 checks Application config first, which overrides
    # any persistent_term cache, so parallel test files cannot interfere.
    Application.put_env(:tet_core, Tet.Retention.Policy,
      ack_secret: "00000000000000000000000000000000"
    )

    {:ok, policy} = Policy.new([])
    %{policy: policy}
  end

  describe "check_before_delete/3" do
    test "allows deletion of transient data", %{policy: policy} do
      assert Enforcer.check_before_delete(policy, :checkpoint, "cp_001") == :ok
    end

    test "allows deletion of normal data", %{policy: policy} do
      assert Enforcer.check_before_delete(policy, :artifact, "art_001") == :ok
    end

    test "blocks deletion of audit-critical data without acknowledgement", %{policy: policy} do
      assert Enforcer.check_before_delete(policy, :error_log, "err_001") ==
               {:error, :audit_protected}

      assert Enforcer.check_before_delete(policy, :event_log, "evt_001") ==
               {:error, :audit_protected}
    end

    test "blocks deletion of permanent data", %{policy: policy} do
      assert Enforcer.check_before_delete(policy, :approval, "ap_001") ==
               {:error, :permanent}
    end
  end

  describe "acknowledge_delete/3" do
    test "generates a token for audit-critical data", %{policy: policy} do
      assert {:ok, token} = Enforcer.acknowledge_delete(policy, :error_log, "err_001")
      assert is_binary(token)
    end

    test "returns error for permanent data", %{policy: policy} do
      assert Enforcer.acknowledge_delete(policy, :approval, "ap_001") ==
               {:error, :permanent}
    end

    test "returns error for non-audit-protected data", %{policy: policy} do
      assert Enforcer.acknowledge_delete(policy, :checkpoint, "cp_001") ==
               {:error, :not_audit_protected}
    end

    test "accepts actor option", %{policy: policy} do
      assert {:ok, token} =
               Enforcer.acknowledge_delete(policy, :error_log, "err_001", actor: "ops_user")

      assert is_binary(token)
    end
  end

  describe "acknowledged_delete/4" do
    test "validates a correct token", %{policy: policy} do
      {:ok, token} = Enforcer.acknowledge_delete(policy, :error_log, "err_001")
      assert Enforcer.acknowledged_delete(policy, :error_log, "err_001", token) == :ok
    end

    test "rejects an incorrect token", %{policy: policy} do
      assert Enforcer.acknowledged_delete(policy, :error_log, "err_001", "bad_token") ==
               {:error, :invalid_ack_token}
    end

    test "rejects token for wrong record ID", %{policy: policy} do
      {:ok, token} = Enforcer.acknowledge_delete(policy, :error_log, "err_001")

      assert Enforcer.acknowledged_delete(policy, :error_log, "err_002", token) ==
               {:error, :invalid_ack_token}
    end

    test "rejects token for wrong data type", %{policy: policy} do
      {:ok, token} = Enforcer.acknowledge_delete(policy, :error_log, "err_001")
      # :approval maps to :permanent — returns :permanent before token check
      assert Enforcer.acknowledged_delete(policy, :approval, "err_001", token) ==
               {:error, :permanent}
    end

    test "returns error for permanent data types", %{policy: policy} do
      # Any token attempt for a permanent type returns :permanent
      assert Enforcer.acknowledged_delete(policy, :approval, "ap_001", "some_token") ==
               {:error, :permanent}
    end
  end

  describe "expired_records/3" do
    test "returns empty for audit-critical data types", %{policy: policy} do
      old_record = %{id: "old", created_at: ~U[2020-01-01 00:00:00Z]}
      assert {:ok, []} = Enforcer.expired_records(policy, :error_log, [old_record])
    end

    test "returns empty for permanent data types", %{policy: policy} do
      old_record = %{id: "old", created_at: ~U[2020-01-01 00:00:00Z]}
      assert {:ok, []} = Enforcer.expired_records(policy, :approval, [old_record])
    end

    test "returns expired records by TTL for transient data", %{policy: policy} do
      old_record = %{id: "old", created_at: ~U[2020-01-01 00:00:00Z]}
      recent_record = %{id: "new", created_at: ~U[2030-01-01 00:00:00Z]}

      assert {:ok, expired} =
               Enforcer.expired_records(policy, :checkpoint, [old_record, recent_record])

      assert length(expired) == 1
      assert hd(expired).id == "old"
    end

    test "returns oldest records when count exceeds max_count" do
      {:ok, policy} = Policy.new(classes: [transient: [max_count: 2, ttl_seconds: nil]])

      records = [
        %{id: "r1", created_at: ~U[2023-01-01 00:00:00Z]},
        %{id: "r2", created_at: ~U[2024-01-01 00:00:00Z]},
        %{id: "r3", created_at: ~U[2025-01-01 00:00:00Z]}
      ]

      assert {:ok, expired} = Enforcer.expired_records(policy, :checkpoint, records)
      assert length(expired) == 1
      assert hd(expired).id == "r1"
    end

    test "returns empty when records are under max_count with no TTL", %{policy: _policy} do
      # Override transient to have no TTL and a high max_count
      {:ok, no_ttl_policy} = Policy.new(classes: [transient: [ttl_seconds: nil, max_count: 100]])

      records = [
        %{id: "r1", created_at: ~U[2023-01-01 00:00:00Z]},
        %{id: "r2", created_at: ~U[2024-01-01 00:00:00Z]}
      ]

      assert {:ok, []} = Enforcer.expired_records(no_ttl_policy, :checkpoint, records)
    end

    test "handles records with ISO 8601 string timestamps" do
      {:ok, policy} = Policy.new(classes: [transient: [ttl_seconds: 0, max_count: nil]])

      records = [
        %{id: "old", created_at: "2020-01-01T00:00:00Z"}
      ]

      assert {:ok, expired} = Enforcer.expired_records(policy, :checkpoint, records)
      assert length(expired) == 1
    end

    test "sorts multiple ISO 8601 string timestamps without crashing" do
      {:ok, policy} = Policy.new(classes: [transient: [ttl_seconds: 86_400, max_count: 1]])

      now = DateTime.utc_now()

      records = [
        %{
          id: "oldest",
          created_at: DateTime.add(now, -172_800, :second) |> DateTime.to_iso8601()
        },
        %{id: "middle", created_at: DateTime.add(now, -86_400, :second) |> DateTime.to_iso8601()},
        %{id: "newest", created_at: now |> DateTime.to_iso8601()}
      ]

      assert {:ok, expired} = Enforcer.expired_records(policy, :checkpoint, records)
      # With max_count=1, oldest and middle are both TTL-expired → 2 expired
      assert length(expired) == 2
      expired_ids = Enum.map(expired, & &1.id)
      assert "oldest" in expired_ids
      assert "middle" in expired_ids
      refute "newest" in expired_ids
    end

    test "respects TTL-based + count-based expiration together" do
      # 2 records: one old (exceeds TTL), one recent (within TTL)
      # max_count = 1 → the recent one stays, the old one is expired
      {:ok, policy} =
        Policy.new(classes: [transient: [ttl_seconds: 86_400, max_count: 1]])

      now = DateTime.utc_now()
      old = %{id: "old", created_at: DateTime.add(now, -172_800, :second)}
      recent = %{id: "recent", created_at: now}

      assert {:ok, expired} = Enforcer.expired_records(policy, :checkpoint, [old, recent])

      # Old is expired by TTL and also by count (only 1 of 2 can stay)
      # Recent stays because it's within TTL
      assert length(expired) == 1
      assert hd(expired).id == "old"
    end
  end

  describe "enforce/4" do
    test "returns 0 for audit-critical data types (never auto-pruned)", %{policy: policy} do
      assert Enforcer.enforce(policy, nil, :error_log,
               store_fun: fn _, _, _ ->
                 {:ok, [%{id: "e1", created_at: ~U[2020-01-01 00:00:00Z]}]}
               end,
               delete_fun: fn _, _, _ -> {:ok, :ok} end
             ) == {:ok, 0}
    end

    test "returns 0 for permanent data types", %{policy: policy} do
      assert Enforcer.enforce(policy, nil, :approval,
               store_fun: fn _, _, _ ->
                 {:ok, [%{id: "a1", created_at: ~U[2020-01-01 00:00:00Z]}]}
               end,
               delete_fun: fn _, _, _ -> {:ok, :ok} end
             ) == {:ok, 0}
    end

    test "deletes expired transient records", %{policy: policy} do
      delete_fun = fn _store, id, _opts ->
        send(self(), {:deleted, id})
        {:ok, :ok}
      end

      assert {:ok, 1} =
               Enforcer.enforce(policy, nil, :checkpoint,
                 store_fun: fn _, _, _ ->
                   {:ok, [%{id: "old", created_at: ~U[2020-01-01 00:00:00Z]}]}
                 end,
                 delete_fun: delete_fun
               )

      assert_received {:deleted, "old"}
    end

    test "returns error when no store/delete functions provided", %{policy: policy} do
      assert Enforcer.enforce(policy, nil, :checkpoint) ==
               {:error, :missing_store_or_delete_function}
    end

    test "returns deleted count from enforce with mixed records" do
      {:ok, policy} =
        Policy.new(classes: [transient: [ttl_seconds: 86_400, max_count: 2]])

      now = DateTime.utc_now()
      old = %{id: "old", created_at: DateTime.add(now, -172_800, :second)}
      recent1 = %{id: "r1", created_at: now}
      recent2 = %{id: "r2", created_at: now}

      records = [old, recent1, recent2]

      delete_fun = fn _store, id, _opts ->
        send(self(), {:deleted, id})
        {:ok, :ok}
      end

      assert {:ok, 1} =
               Enforcer.enforce(policy, nil, :checkpoint,
                 store_fun: fn _, _, _ -> {:ok, records} end,
                 delete_fun: delete_fun
               )
    end
  end

  describe "describe/2" do
    test "produces a human-readable description for transient data", %{policy: policy} do
      desc = Enforcer.describe(policy, :checkpoint)
      assert desc =~ "checkpoint"
      assert desc =~ "transient"
      assert desc =~ "TTL=86400s"
      assert desc =~ "auto-deletable"
    end

    test "produces a human-readable description for audit-critical data", %{policy: policy} do
      desc = Enforcer.describe(policy, :error_log)
      assert desc =~ "error_log"
      assert desc =~ "audit_critical"
      assert desc =~ "audit-protected"
    end

    test "produces a human-readable description for permanent data", %{policy: policy} do
      desc = Enforcer.describe(policy, :approval)
      assert desc =~ "approval"
      assert desc =~ "permanent"
      assert desc =~ "no TTL"
      assert desc =~ "audit-protected"
    end
  end
end
