defmodule Tet.Migration.SafetyCheckTest do
  use ExUnit.Case, async: true

  alias Tet.Migration
  alias Tet.Migration.SafetyCheck

  defp build_migration(attrs) do
    defaults = [
      source_path: "/src/config.json",
      target_path: "/tgt/config.json",
      backup_path: "/tgt/config.json.bak",
      mode: :dry_run,
      items: [],
      warnings: [],
      status: :analyzed
    ]

    struct!(Migration, Keyword.merge(defaults, attrs))
  end

  describe "check_serialized_data/1" do
    test "returns empty list when no items contain serialized data" do
      m = build_migration(items: [%{key: "model", value: "gpt-4"}])

      assert [] == SafetyCheck.check_serialized_data(m)
    end

    test "flags items with struct-like patterns" do
      m =
        build_migration(
          items: [
            %{key: "model", value: "gpt-4"},
            %{key: "sketchy", value: "%{__struct__: Dodgy, payload: :evil}"}
          ]
        )

      unsafe = SafetyCheck.check_serialized_data(m)
      assert "sketchy" in unsafe
      assert "model" not in unsafe
    end

    test "flags items with Code.eval_string patterns" do
      m =
        build_migration(
          items: [
            %{key: "danger", value: "Code.eval_string(\"IO.puts(:pwned)\")"}
          ]
        )

      unsafe = SafetyCheck.check_serialized_data(m)
      assert "danger" in unsafe
    end

    test "handles string-keyed items" do
      m =
        build_migration(
          items: [
            %{"key" => "injected", "value" => "require Logger"}
          ]
        )

      unsafe = SafetyCheck.check_serialized_data(m)
      assert "injected" in unsafe
    end
  end

  describe "check_backup_exists/1" do
    test "returns error when backup_path is nil" do
      m = build_migration(backup_path: nil)
      assert {:error, :no_backup_path} == SafetyCheck.check_backup_exists(m)
    end

    test "returns error when backup file does not exist" do
      m = build_migration(backup_path: "/tmp/nonexistent_backup_12345.bak")
      assert {:error, {:backup_not_found, _}} = SafetyCheck.check_backup_exists(m)
    end

    test "returns :ok when backup file exists" do
      # Create a temp file for the test
      tmp_path =
        System.tmp_dir!()
        |> Path.join("migration_backup_test_#{:erlang.unique_integer([:positive])}.bak")

      File.write!(tmp_path, "backup data")

      try do
        m = build_migration(backup_path: tmp_path)
        assert :ok == SafetyCheck.check_backup_exists(m)
      after
        File.rm(tmp_path)
      end
    end
  end

  describe "warnings/1" do
    test "includes plan warnings" do
      m = build_migration(warnings: ["something is fishy"])

      warnings = SafetyCheck.warnings(m)
      assert "something is fishy" in warnings
    end

    test "includes serialized data warnings" do
      m =
        build_migration(
          items: [%{key: "evil", value: "%{__struct__: Bad, data: :stuff}"}],
          warnings: []
        )

      warnings = SafetyCheck.warnings(m)
      assert Enum.any?(warnings, &String.contains?(&1, "serialized data"))
    end

    test "includes backup warning in execute mode without backup" do
      m = build_migration(mode: :execute, backup_path: nil)

      warnings = SafetyCheck.warnings(m)
      assert Enum.any?(warnings, &String.contains?(&1, "Backup"))
    end

    test "no backup warning in dry_run mode" do
      m = build_migration(mode: :dry_run, backup_path: nil)

      warnings = SafetyCheck.warnings(m)
      refute Enum.any?(warnings, &String.contains?(&1, "Backup"))
    end

    test "no backup warning when backup exists in execute mode" do
      tmp_path =
        System.tmp_dir!()
        |> Path.join("migration_backup_warn_test_#{:erlang.unique_integer([:positive])}.bak")

      File.write!(tmp_path, "backup data")

      try do
        m = build_migration(mode: :execute, backup_path: tmp_path)

        warnings = SafetyCheck.warnings(m)
        refute Enum.any?(warnings, &String.contains?(&1, "Backup"))
      after
        File.rm(tmp_path)
      end
    end
  end

  describe "safe_to_execute?/1" do
    test "always true for dry_run mode" do
      m = build_migration(mode: :dry_run)
      assert SafetyCheck.safe_to_execute?(m)
    end

    test "false for execute mode without backup" do
      m = build_migration(mode: :execute, backup_path: nil)
      refute SafetyCheck.safe_to_execute?(m)
    end

    test "false for execute mode with serialized data" do
      tmp_path =
        System.tmp_dir!()
        |> Path.join("migration_safe_test_#{:erlang.unique_integer([:positive])}.bak")

      File.write!(tmp_path, "backup data")

      try do
        m =
          build_migration(
            mode: :execute,
            backup_path: tmp_path,
            items: [%{key: "evil", value: "%{__struct__: Bad}"}]
          )

        refute SafetyCheck.safe_to_execute?(m)
      after
        File.rm(tmp_path)
      end
    end

    test "true for execute mode when all checks pass" do
      tmp_path =
        System.tmp_dir!()
        |> Path.join("migration_safe_ok_#{:erlang.unique_integer([:positive])}.bak")

      File.write!(tmp_path, "backup data")

      try do
        m =
          build_migration(
            mode: :execute,
            backup_path: tmp_path,
            items: [%{key: "model", value: "gpt-4"}],
            warnings: []
          )

        assert SafetyCheck.safe_to_execute?(m)
      after
        File.rm(tmp_path)
      end
    end

    test "false for unknown mode" do
      m = build_migration(mode: :invalid)
      refute SafetyCheck.safe_to_execute?(m)
    end
  end
end
