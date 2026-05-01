defmodule Tet.ErrorLogTest do
  use ExUnit.Case, async: true

  @moduletag :tet_core

  @now ~U[2024-01-02 03:04:05Z]
  @later ~U[2024-01-02 03:05:06Z]

  describe "new/1" do
    test "builds a valid error log entry with minimum attrs" do
      assert {:ok, entry} =
               Tet.ErrorLog.new(%{
                 id: "err_min_001",
                 session_id: "ses_test",
                 kind: :exception,
                 message: "Boom!"
               })

      assert entry.id == "err_min_001"
      assert entry.session_id == "ses_test"
      assert entry.kind == :exception
      assert entry.message == "Boom!"
      assert entry.status == :open
      assert entry.stacktrace == nil
      assert entry.metadata == %{}
    end

    test "accepts all trigger classes" do
      trigger_classes = [
        :exception,
        :crash,
        :compile_failure,
        :smoke_failure,
        :remote_failure,
        :provider_error,
        :tool_error,
        :verification_error,
        :auth_error,
        :rate_limit_error,
        :timeout_error,
        :parse_error,
        :policy_error,
        :store_error,
        :unknown_error
      ]

      for kind <- trigger_classes do
        assert {:ok, entry} =
                 Tet.ErrorLog.new(%{
                   id: "err_#{kind}",
                   session_id: "ses_test",
                   kind: kind,
                   message: "Test #{kind}"
                 })

        assert entry.kind == kind
      end
    end

    test "accepts string keyed attrs" do
      assert {:ok, entry} =
               Tet.ErrorLog.new(%{
                 "id" => "err_str_001",
                 "session_id" => "ses_test",
                 "kind" => "exception",
                 "message" => "String keys work"
               })

      assert entry.id == "err_str_001"
      assert entry.kind == :exception
    end

    test "accepts stacktrace field" do
      assert {:ok, entry} =
               Tet.ErrorLog.new(%{
                 id: "err_st_001",
                 session_id: "ses_test",
                 kind: :exception,
                 message: "With stacktrace",
                 stacktrace: "** (RuntimeError) boom\\n  file.ex:1"
               })

      assert entry.stacktrace == "** (RuntimeError) boom\\n  file.ex:1"
    end

    test "accepts :dismissed status" do
      assert {:ok, entry} =
               Tet.ErrorLog.new(%{
                 id: "err_dismiss_001",
                 session_id: "ses_test",
                 kind: :crash,
                 message: "Dismissed crash",
                 status: :dismissed
               })

      assert entry.status == :dismissed
    end

    test "rejects invalid trigger class" do
      assert {:error, {:invalid_error_log_field, :kind}} =
               Tet.ErrorLog.new(%{
                 id: "err_bad",
                 session_id: "ses_test",
                 kind: :made_up_kind,
                 message: "Bad kind"
               })
    end

    test "rejects missing required fields" do
      assert {:error, {:invalid_entity_field, :error_log, :id}} =
               Tet.ErrorLog.new(%{session_id: "ses_test", kind: :exception, message: "x"})

      assert {:error, {:invalid_entity_field, :error_log, :session_id}} =
               Tet.ErrorLog.new(%{id: "err_001", kind: :exception, message: "x"})

      assert {:error, {:invalid_error_log_field, :kind}} =
               Tet.ErrorLog.new(%{id: "err_001", session_id: "ses_test", message: "x"})

      assert {:error, {:invalid_entity_field, :error_log, :message}} =
               Tet.ErrorLog.new(%{id: "err_001", session_id: "ses_test", kind: :exception})
    end

    test "rejects invalid status" do
      assert {:error, {:invalid_error_log_field, :status}} =
               Tet.ErrorLog.new(%{
                 id: "err_bad_st",
                 session_id: "ses_test",
                 kind: :exception,
                 message: "x",
                 status: :bogus
               })
    end

    test "rejects empty string for required binary fields" do
      assert {:error, {:invalid_entity_field, :error_log, :id}} =
               Tet.ErrorLog.new(%{id: "", session_id: "ses_test", kind: :exception, message: "x"})
    end
  end

  describe "to_map/1 and from_map/1 round-trip" do
    test "round-trips all fields" do
      attrs = %{
        id: "err_rt_001",
        session_id: "ses_test",
        task_id: "task_001",
        kind: :exception,
        message: "Round trip test",
        stacktrace: "** (RuntimeError) boom\\n  file.ex:1",
        context: %{key: "val"},
        status: :open,
        resolved_at: nil,
        created_at: @now,
        metadata: %{"origin" => "test"}
      }

      assert {:ok, entry} = Tet.ErrorLog.new(attrs)
      map = Tet.ErrorLog.to_map(entry)
      assert {:ok, ^entry} = Tet.ErrorLog.from_map(map)
    end

    test "round-trips resolved error" do
      attrs = %{
        id: "err_resolved_001",
        session_id: "ses_test",
        kind: :provider_error,
        message: "Rate limited",
        status: :resolved,
        resolved_at: @later
      }

      assert {:ok, entry} = Tet.ErrorLog.new(attrs)
      map = Tet.ErrorLog.to_map(entry)
      assert {:ok, ^entry} = Tet.ErrorLog.from_map(map)
    end

    test "round-trips dismissed error" do
      attrs = %{
        id: "err_dismiss_rt",
        session_id: "ses_test",
        kind: :smoke_failure,
        message: "Smoke test failed",
        status: :dismissed
      }

      assert {:ok, entry} = Tet.ErrorLog.new(attrs)
      map = Tet.ErrorLog.to_map(entry)
      assert {:ok, ^entry} = Tet.ErrorLog.from_map(map)
    end
  end

  describe "resolve/2" do
    test "sets status to :resolved and records timestamp" do
      assert {:ok, entry} =
               Tet.ErrorLog.new(%{
                 id: "err_res_001",
                 session_id: "ses_test",
                 kind: :exception,
                 message: "Will be resolved"
               })

      resolved = Tet.ErrorLog.resolve(entry, @later)
      assert resolved.status == :resolved
      assert resolved.resolved_at == @later
    end

    test "rejects binary string for resolved_at" do
      assert {:ok, entry} =
               Tet.ErrorLog.new(%{
                 id: "err_res_002",
                 session_id: "ses_test",
                 kind: :exception,
                 message: "Bad resolve"
               })

      assert_raise FunctionClauseError, fn ->
        Tet.ErrorLog.resolve(entry, "2024-01-02T03:05:06Z")
      end
    end
  end

  describe "statuses/0" do
    test "returns all valid statuses" do
      assert Tet.ErrorLog.statuses() == [:open, :resolved, :dismissed]
    end
  end
end
