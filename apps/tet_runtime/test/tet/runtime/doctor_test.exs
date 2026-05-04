defmodule Tet.Runtime.DoctorTest do
  use ExUnit.Case, async: false

  alias Tet.Runtime.Doctor

  # ── Unit tests (no repo needed) ──────────────────────────────────────

  describe "validate_configured_store_path/2" do
    test "returns :ok when path is nil (no explicit store path configured)" do
      assert Doctor.validate_configured_store_path(nil, %{}) == :ok
    end

    test "returns :ok when path is empty string" do
      assert Doctor.validate_configured_store_path("", %{}) == :ok
    end

    test "returns error when directory does not exist" do
      health = %{dir_exists?: false, writable?: false}

      assert {:error, msg} = Doctor.validate_configured_store_path("/nonexistent/path", health)
      assert msg =~ "/nonexistent/path"
      assert msg =~ "check TET_STORE_PATH"
    end

    test "returns error when directory exists but is not writable" do
      health = %{dir_exists?: true, writable?: false}

      assert {:error, msg} =
               Doctor.validate_configured_store_path("/some/path", health)

      assert msg =~ "not writable"
      assert msg =~ "/some/path"
      assert msg =~ "check permissions and TET_STORE_PATH"
    end

    test "returns :ok when directory exists and is writable" do
      health = %{dir_exists?: true, writable?: true}

      assert Doctor.validate_configured_store_path("/some/path", health) == :ok
    end
  end

  describe "store_health_message/1" do
    test "builds rich message for SQLite health map with WAL and schema version" do
      sqlite_health = %{
        format: :sqlite,
        status: :ok,
        journal_mode: "wal",
        schema_version: 7
      }

      assert Doctor.store_health_message(sqlite_health) ==
               "SQLite store healthy (WAL mode, schema v7)"
    end

    test "builds message with non-WAL journal mode" do
      sqlite_health = %{
        format: :sqlite,
        status: :ok,
        journal_mode: "delete",
        schema_version: 3
      }

      assert Doctor.store_health_message(sqlite_health) ==
               "SQLite store healthy (DELETE mode, schema v3)"
    end

    test "falls back to generic message when format is not :sqlite" do
      generic_health = %{status: :ok, application: :other_adapter}

      assert Doctor.store_health_message(generic_health) ==
               "store path is readable and writable"
    end

    test "falls back to generic message when schema_version is nil" do
      health = %{format: :sqlite, status: :ok, journal_mode: "wal", schema_version: nil}

      assert Doctor.store_health_message(health) ==
               "store path is readable and writable"
    end

    test "falls back when journal_mode is nil" do
      health = %{format: :sqlite, status: :ok, journal_mode: nil, schema_version: 7}

      assert Doctor.store_health_message(health) ==
               "store path is readable and writable"
    end

    test "falls back when journal_mode is an atom instead of binary" do
      health = %{format: :sqlite, status: :ok, journal_mode: :wal, schema_version: 7}

      assert Doctor.store_health_message(health) ==
               "store path is readable and writable"
    end

    test "falls back when schema_version is a string instead of integer" do
      health = %{format: :sqlite, status: :ok, journal_mode: "wal", schema_version: "7"}

      assert Doctor.store_health_message(health) ==
               "store path is readable and writable"
    end

    test "falls back when both keys are missing" do
      health = %{status: :ok, application: :tet_store_sqlite}

      assert Doctor.store_health_message(health) ==
               "store path is readable and writable"
    end

    test "falls back when health map is nil" do
      assert Doctor.store_health_message(nil) ==
               "store path is readable and writable"
    end
  end

  # ── Integration test (uses configured adapter) ────────────────────────

  describe "Doctor.run/1 with SQLite adapter" do
    test "store check surfaces SQLite schema version and journal mode" do
      assert {:ok, report} = Doctor.run()

      store_check =
        Enum.find(report.checks, &(&1.name == :store))

      assert store_check.status == :ok
      assert store_check.message =~ "SQLite store healthy"
      assert store_check.message =~ "mode"
      assert store_check.message =~ "schema v"

      # Details must contain the raw SQLite-specific fields with correct types
      assert is_binary(report.store.journal_mode)
      assert is_integer(report.store.schema_version)
    end
  end
end
