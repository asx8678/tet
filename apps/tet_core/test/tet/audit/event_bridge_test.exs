defmodule Tet.Audit.EventBridgeTest do
  use ExUnit.Case, async: true

  alias Tet.Audit
  alias Tet.Audit.EventBridge
  alias Tet.Event

  describe "event_type_mapping/0" do
    test "returns a map of event types to audit event types" do
      mapping = EventBridge.event_type_mapping()

      assert is_map(mapping)
      assert map_size(mapping) > 0

      # Every mapped value is a valid audit event type
      for {_event_type, audit_type} <- mapping do
        assert audit_type in Audit.event_types()
      end
    end

    test "covers tool events" do
      mapping = EventBridge.event_type_mapping()
      assert mapping[:"tool.requested"] == :tool_call
      assert mapping[:"tool.started"] == :tool_call
      assert mapping[:"tool.finished"] == :tool_call
      assert mapping[:"tool.blocked"] == :tool_call
    end

    test "covers message events" do
      mapping = EventBridge.event_type_mapping()
      assert mapping[:"message.user.saved"] == :message
      assert mapping[:"message.assistant.saved"] == :message
    end

    test "covers approval events" do
      mapping = EventBridge.event_type_mapping()
      assert mapping[:"approval.created"] == :approval
      assert mapping[:"approval.approved"] == :approval
      assert mapping[:"approval.rejected"] == :approval
    end

    test "covers error events" do
      mapping = EventBridge.event_type_mapping()
      assert mapping[:"error.recorded"] == :error
      assert mapping[:provider_error] == :error
    end

    test "covers config change events" do
      mapping = EventBridge.event_type_mapping()
      assert mapping[:"session.created"] == :config_change
      assert mapping[:"workspace.created"] == :config_change
      assert mapping[:"workspace.trusted"] == :config_change
    end

    test "covers repair events" do
      mapping = EventBridge.event_type_mapping()
      assert mapping[:"verifier.started"] == :repair
      assert mapping[:"verifier.finished"] == :repair
    end
  end

  describe "from_event/1" do
    test "converts a tool event to an audit entry" do
      event = %Event{
        id: "evt_tool_1",
        type: :"tool.finished",
        session_id: "ses_1",
        payload: %{tool_name: "write_file", file_path: "/lib/foo.ex"},
        metadata: %{duration_ms: 42},
        created_at: ~U[2025-05-01 12:00:00Z]
      }

      assert {:ok, audit} = EventBridge.from_event(event)
      assert audit.event_type == :tool_call
      assert audit.action == :execute
      assert audit.actor == :agent
      assert audit.session_id == "ses_1"
      assert audit.resource == "/lib/foo.ex"
      assert audit.outcome == :success
      assert audit.payload_ref == "payload:evt_tool_1"
      assert audit.id == "aud_evt_evt_tool_1"
    end

    test "converts a user message event to an audit entry" do
      event = %Event{
        id: "evt_msg_1",
        type: :"message.user.saved",
        session_id: "ses_2",
        payload: %{},
        metadata: %{},
        created_at: ~U[2025-05-01 12:00:00Z]
      }

      assert {:ok, audit} = EventBridge.from_event(event)
      assert audit.event_type == :message
      assert audit.action == :create
      assert audit.actor == :user
    end

    test "converts an assistant message event to an audit entry" do
      event = %Event{
        id: "evt_msg_2",
        type: :"message.assistant.saved",
        session_id: "ses_2",
        payload: %{},
        metadata: %{},
        created_at: ~U[2025-05-01 12:00:00Z]
      }

      assert {:ok, audit} = EventBridge.from_event(event)
      assert audit.event_type == :message
      assert audit.actor == :agent
    end

    test "converts an approval event with correct actor" do
      approved = %Event{
        id: "evt_appr",
        type: :"approval.approved",
        session_id: "ses_3",
        payload: %{approver: "adam"},
        metadata: %{},
        created_at: ~U[2025-05-01 12:00:00Z]
      }

      assert {:ok, audit} = EventBridge.from_event(approved)
      assert audit.event_type == :approval
      assert audit.action == :update
      assert audit.actor == :user
      assert audit.outcome == :success
    end

    test "converts a rejected approval with denied outcome" do
      rejected = %Event{
        id: "evt_rej",
        type: :"approval.rejected",
        session_id: "ses_3",
        payload: %{},
        metadata: %{},
        created_at: ~U[2025-05-01 12:00:00Z]
      }

      assert {:ok, audit} = EventBridge.from_event(rejected)
      assert audit.outcome == :denied
      assert audit.actor == :user
    end

    test "converts an error event" do
      event = %Event{
        id: "evt_err",
        type: :"error.recorded",
        session_id: "ses_4",
        payload: %{},
        metadata: %{},
        created_at: ~U[2025-05-01 12:00:00Z]
      }

      assert {:ok, audit} = EventBridge.from_event(event)
      assert audit.event_type == :error
      assert audit.outcome == :failure
    end

    test "converts a blocked tool event with denied outcome" do
      event = %Event{
        id: "evt_block",
        type: :"tool.blocked",
        session_id: "ses_5",
        payload: %{tool_name: "shell"},
        metadata: %{},
        created_at: ~U[2025-05-01 12:00:00Z]
      }

      assert {:ok, audit} = EventBridge.from_event(event)
      assert audit.event_type == :tool_call
      assert audit.outcome == :denied
      assert audit.resource == "shell"
    end

    test "converts a session created event" do
      event = %Event{
        id: "evt_ses",
        type: :"session.created",
        session_id: "ses_6",
        payload: %{},
        metadata: %{},
        created_at: ~U[2025-05-01 12:00:00Z]
      }

      assert {:ok, audit} = EventBridge.from_event(event)
      assert audit.event_type == :config_change
      assert audit.action == :create
      assert audit.actor == :system
    end

    test "converts a provider event as system actor" do
      event = %Event{
        id: "evt_prov",
        type: :provider_start,
        session_id: "ses_7",
        payload: %{},
        metadata: %{},
        created_at: ~U[2025-05-01 12:00:00Z]
      }

      assert {:ok, audit} = EventBridge.from_event(event)
      assert audit.actor == :system
    end

    test "converts a verifier event as repair type" do
      event = %Event{
        id: "evt_ver",
        type: :"verifier.started",
        session_id: "ses_8",
        payload: %{},
        metadata: %{},
        created_at: ~U[2025-05-01 12:00:00Z]
      }

      assert {:ok, audit} = EventBridge.from_event(event)
      assert audit.event_type == :repair
      assert audit.actor == :system
      assert audit.outcome == :pending
    end

    test "extracts resource from file_path in payload" do
      event = %Event{
        id: "evt_res1",
        type: :"patch.applied",
        session_id: "ses_9",
        payload: %{file_path: "/lib/baz.ex"},
        metadata: %{},
        created_at: ~U[2025-05-01 12:00:00Z]
      }

      assert {:ok, audit} = EventBridge.from_event(event)
      assert audit.resource == "/lib/baz.ex"
    end

    test "extracts resource from tool_name when no file_path" do
      event = %Event{
        id: "evt_res2",
        type: :"tool.finished",
        session_id: "ses_10",
        payload: %{tool_name: "grep"},
        metadata: %{},
        created_at: ~U[2025-05-01 12:00:00Z]
      }

      assert {:ok, audit} = EventBridge.from_event(event)
      assert audit.resource == "grep"
    end

    test "falls back to event type string as resource" do
      event = %Event{
        id: "evt_res3",
        type: :provider_done,
        session_id: "ses_11",
        payload: %{stop_reason: :end_turn},
        metadata: %{},
        created_at: ~U[2025-05-01 12:00:00Z]
      }

      assert {:ok, audit} = EventBridge.from_event(event)
      assert audit.resource == "provider_done"
    end

    test "handles event without id" do
      event = %Event{
        type: :"tool.started",
        session_id: "ses_12",
        payload: %{tool_name: "read"},
        metadata: %{},
        created_at: ~U[2025-05-01 12:00:00Z]
      }

      assert {:ok, audit} = EventBridge.from_event(event)
      assert String.starts_with?(audit.id, "aud_")
      assert audit.payload_ref == nil
    end

    test "handles event without created_at" do
      event = %Event{
        id: "evt_nots",
        type: :"tool.finished",
        session_id: "ses_13",
        payload: %{},
        metadata: %{}
      }

      assert {:ok, audit} = EventBridge.from_event(event)
      assert %DateTime{} = audit.timestamp
    end

    test "parses ISO8601 string timestamp" do
      event = %Event{
        id: "evt_iso",
        type: :"tool.finished",
        session_id: "ses_iso",
        payload: %{},
        metadata: %{},
        created_at: "2025-05-01T12:00:00Z"
      }

      assert {:ok, audit} = EventBridge.from_event(event)
      assert audit.timestamp == ~U[2025-05-01 12:00:00Z]
    end

    test "falls back to utc_now for invalid ISO8601 string" do
      event = %Event{
        id: "evt_badiso",
        type: :"tool.finished",
        session_id: "ses_badiso",
        payload: %{},
        metadata: %{},
        created_at: "not-a-timestamp"
      }

      assert {:ok, audit} = EventBridge.from_event(event)
      assert %DateTime{} = audit.timestamp
    end

    test "handles unknown event type with default classification" do
      event = %Event{
        id: "evt_unknown",
        type: :assistant_chunk,
        session_id: "ses_14",
        payload: %{},
        metadata: %{},
        created_at: ~U[2025-05-01 12:00:00Z]
      }

      assert {:ok, audit} = EventBridge.from_event(event)
      # Unknown types default to :tool_call
      assert audit.event_type == :tool_call
    end

    test "read_tool events get :read action" do
      event = %Event{
        id: "evt_read",
        type: :"read_tool.started",
        session_id: "ses_15",
        payload: %{tool_name: "read"},
        metadata: %{},
        created_at: ~U[2025-05-01 12:00:00Z]
      }

      assert {:ok, audit} = EventBridge.from_event(event)
      assert audit.action == :read
    end
  end
end
