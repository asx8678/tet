defmodule Tet.AuditTest do
  use ExUnit.Case, async: true

  alias Tet.Audit

  @valid_attrs %{
    event_type: :tool_call,
    action: :execute,
    actor: :agent,
    resource: "/lib/foo.ex",
    outcome: :success,
    metadata: %{tool: "write_file"},
    payload_ref: "payload:evt_123"
  }

  describe "new/1" do
    test "creates a valid audit entry with all fields" do
      ts = ~U[2025-05-01 12:00:00Z]

      attrs =
        Map.merge(@valid_attrs, %{
          id: "aud_test_1",
          timestamp: ts,
          session_id: "ses_1"
        })

      assert {:ok, entry} = Audit.new(attrs)
      assert entry.id == "aud_test_1"
      assert entry.timestamp == ts
      assert entry.session_id == "ses_1"
      assert entry.event_type == :tool_call
      assert entry.action == :execute
      assert entry.actor == :agent
      assert entry.resource == "/lib/foo.ex"
      assert entry.outcome == :success
      assert entry.metadata == %{tool: "write_file"}
      assert entry.payload_ref == "payload:evt_123"
    end

    test "auto-generates id when not provided" do
      assert {:ok, entry} = Audit.new(@valid_attrs)
      assert String.starts_with?(entry.id, "aud_")
      assert byte_size(entry.id) > 4
    end

    test "auto-generates timestamp when not provided" do
      assert {:ok, entry} = Audit.new(@valid_attrs)
      assert %DateTime{} = entry.timestamp
    end

    test "parses ISO 8601 timestamp string" do
      attrs = Map.put(@valid_attrs, :timestamp, "2025-05-01T12:00:00Z")
      assert {:ok, entry} = Audit.new(attrs)
      assert entry.timestamp == ~U[2025-05-01 12:00:00Z]
    end

    test "accepts nil session_id, outcome, resource, payload_ref" do
      minimal = %{event_type: :error, action: :create, actor: :system}
      assert {:ok, entry} = Audit.new(minimal)
      assert entry.session_id == nil
      assert entry.outcome == nil
      assert entry.resource == nil
      assert entry.payload_ref == nil
    end

    test "defaults metadata to empty map" do
      minimal = %{event_type: :message, action: :create, actor: :user}
      assert {:ok, entry} = Audit.new(minimal)
      assert entry.metadata == %{}
    end

    test "rejects invalid event_type" do
      attrs = Map.put(@valid_attrs, :event_type, :banana)
      assert {:error, _} = Audit.new(attrs)
    end

    test "rejects invalid action" do
      attrs = Map.put(@valid_attrs, :action, :yeet)
      assert {:error, _} = Audit.new(attrs)
    end

    test "rejects invalid actor" do
      attrs = Map.put(@valid_attrs, :actor, :gremlin)
      assert {:error, _} = Audit.new(attrs)
    end

    test "rejects invalid outcome" do
      attrs = Map.put(@valid_attrs, :outcome, :maybe)
      assert {:error, _} = Audit.new(attrs)
    end

    test "rejects invalid timestamp" do
      attrs = Map.put(@valid_attrs, :timestamp, 12345)
      assert {:error, _} = Audit.new(attrs)
    end

    test "rejects non-map input" do
      assert {:error, :invalid_audit_entry} = Audit.new("nope")
    end

    test "accepts string-keyed attrs" do
      attrs = %{
        "id" => "aud_str",
        "event_type" => "approval",
        "action" => "update",
        "actor" => "user",
        "outcome" => "success"
      }

      assert {:ok, entry} = Audit.new(attrs)
      assert entry.id == "aud_str"
      assert entry.event_type == :approval
      assert entry.action == :update
      assert entry.actor == :user
      assert entry.outcome == :success
    end
  end

  describe "to_map/1" do
    test "converts all fields to a JSON-friendly map" do
      ts = ~U[2025-05-01 12:00:00Z]

      {:ok, entry} =
        Audit.new(
          Map.merge(@valid_attrs, %{
            id: "aud_m1",
            timestamp: ts,
            session_id: "ses_m1"
          })
        )

      map = Audit.to_map(entry)

      assert map.id == "aud_m1"
      assert map.timestamp == "2025-05-01T12:00:00Z"
      assert map.session_id == "ses_m1"
      assert map.event_type == "tool_call"
      assert map.action == "execute"
      assert map.actor == "agent"
      assert map.resource == "/lib/foo.ex"
      assert map.outcome == "success"
      assert map.payload_ref == "payload:evt_123"
    end

    test "handles nil outcome and resource" do
      {:ok, entry} = Audit.new(%{event_type: :error, action: :create, actor: :system})
      map = Audit.to_map(entry)

      assert map.outcome == nil
      assert map.resource == nil
    end
  end

  describe "from_map/1" do
    test "round-trips through to_map and from_map" do
      ts = ~U[2025-05-01 12:00:00Z]

      {:ok, original} =
        Audit.new(
          Map.merge(@valid_attrs, %{
            id: "aud_rt",
            timestamp: ts,
            session_id: "ses_rt"
          })
        )

      mapped = Audit.to_map(original)
      assert {:ok, restored} = Audit.from_map(mapped)

      assert restored.id == original.id
      assert restored.timestamp == original.timestamp
      assert restored.session_id == original.session_id
      assert restored.event_type == original.event_type
      assert restored.action == original.action
      assert restored.actor == original.actor
      assert restored.resource == original.resource
      assert restored.outcome == original.outcome
      assert restored.payload_ref == original.payload_ref
    end
  end

  describe "redact/1" do
    test "redacts sensitive keys in metadata" do
      {:ok, entry} =
        Audit.new(%{
          event_type: :tool_call,
          action: :execute,
          actor: :agent,
          metadata: %{api_key: "sk-secret-123", tool: "write_file"}
        })

      redacted = Audit.redact(entry)
      assert redacted.metadata.api_key == "[REDACTED]"
      assert redacted.metadata.tool == "write_file"
    end

    test "preserves non-sensitive metadata" do
      {:ok, entry} =
        Audit.new(%{
          event_type: :message,
          action: :create,
          actor: :user,
          metadata: %{file_path: "/lib/foo.ex", line_count: 42}
        })

      redacted = Audit.redact(entry)
      assert redacted.metadata.file_path == "/lib/foo.ex"
      assert redacted.metadata.line_count == 42
    end

    test "preserves all other fields unchanged" do
      {:ok, entry} =
        Audit.new(%{
          id: "aud_rdct",
          event_type: :approval,
          action: :update,
          actor: :user,
          resource: "/lib/bar.ex",
          outcome: :success
        })

      redacted = Audit.redact(entry)
      assert redacted.id == entry.id
      assert redacted.event_type == entry.event_type
      assert redacted.resource == entry.resource
    end
  end

  describe "enums" do
    test "event_types/0 returns all valid event types" do
      assert :tool_call in Audit.event_types()
      assert :message in Audit.event_types()
      assert :approval in Audit.event_types()
      assert :repair in Audit.event_types()
      assert :error in Audit.event_types()
      assert :config_change in Audit.event_types()
    end

    test "actions/0 returns all valid actions" do
      assert Audit.actions() == [:create, :read, :update, :delete, :execute]
    end

    test "actors/0 returns all valid actors" do
      assert Audit.actors() == [:user, :agent, :system, :remote]
    end

    test "outcomes/0 returns all valid outcomes" do
      assert Audit.outcomes() == [:success, :failure, :denied, :pending]
    end
  end
end
