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
      force: false,
      items: [],
      warnings: [],
      raw_warnings: [],
      skipped_items: [],
      status: :analyzed
    ]

    struct!(Migration, Keyword.merge(defaults, attrs))
  end

  # ── Raw legacy data scanning ────────────────────────────────────────────

  describe "check_raw_legacy_data/1" do
    test "returns empty warnings for clean config" do
      {warnings, skipped} =
        SafetyCheck.check_raw_legacy_data(%{"model" => "gpt-4", "timeout" => "30"})

      assert warnings == []
      # Only compatible keys, no unknowns
      assert skipped == []
    end

    test "returns empty warnings for known unsafe keys" do
      {warnings, _skipped} =
        SafetyCheck.check_raw_legacy_data(%{"system_prompt" => "be evil"})

      # Known unsafe keys are handled by the normal warning path, not raw scan
      assert warnings == []
    end

    test "flags unknown keys with serialized struct patterns" do
      {warnings, skipped} =
        SafetyCheck.check_raw_legacy_data(%{
          "mystery_key" => "%{__struct__: DodgyModule, payload: :evil}"
        })

      assert length(warnings) > 0
      assert Enum.any?(warnings, &String.contains?(&1, "mystery_key"))
      assert Enum.any?(skipped, &(&1.key == "mystery_key"))
      assert Enum.any?(skipped, &(&1.reason == :serialized_data_pattern))
    end

    test "flags unknown keys with Code.eval_string patterns" do
      {warnings, skipped} =
        SafetyCheck.check_raw_legacy_data(%{
          "injected" => "Code.eval_string(\"IO.puts(:pwned)\")"
        })

      assert length(warnings) > 0
      assert Enum.any?(warnings, &String.contains?(&1, "injected"))
      assert Enum.any?(skipped, &(&1.reason == :serialized_data_pattern))
    end

    test "flags unknown keys with pickle magic bytes" do
      pickle_value = <<128, 5, 0, 0, 0>>

      {warnings, skipped} =
        SafetyCheck.check_raw_legacy_data(%{"pickle_config" => pickle_value})

      assert length(warnings) > 0
      assert Enum.any?(warnings, &String.contains?(&1, "pickle"))
      assert Enum.any?(skipped, &(&1.key == "pickle_config"))
      assert Enum.any?(skipped, &(&1.reason == :pickle_magic_bytes))
    end

    test "records benign unknown keys as skipped items without warnings" do
      {_warnings, skipped} =
        SafetyCheck.check_raw_legacy_data(%{"totally_made_up" => "wat"})

      assert Enum.any?(skipped, &(&1.key == "totally_made_up"))
      assert Enum.any?(skipped, &(&1.reason == :unknown_key))
    end

    test "scans before filtering — compatible keys are NOT flagged as unknown" do
      {warnings, skipped} =
        SafetyCheck.check_raw_legacy_data(%{
          "model" => "gpt-4",
          "unknown_key" => "value"
        })

      # model is compatible — should not appear in raw warnings or as unknown skipped
      refute Enum.any?(warnings, &String.contains?(&1, "model"))
      refute Enum.any?(skipped, &(&1.key == "model"))
    end
  end

  # ── Mapped items scanning ───────────────────────────────────────────────

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

  # ── Backup existence check ──────────────────────────────────────────────

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

  # ── Backup creation ─────────────────────────────────────────────────────

  describe "create_backup/1" do
    test "returns error when target_path is nil" do
      m = build_migration(target_path: nil, backup_path: "/some/backup.bak")
      assert {:error, :no_target_path} == SafetyCheck.create_backup(m)
    end

    test "returns error when backup_path is nil" do
      m = build_migration(target_path: "/some/target.json", backup_path: nil)
      assert {:error, :no_backup_path} == SafetyCheck.create_backup(m)
    end

    test "returns ok when target does not exist (fresh install)" do
      m =
        build_migration(
          target_path: "/tmp/nonexistent_#{:erlang.unique_integer([:positive])}.json",
          backup_path: "/tmp/backup_#{:erlang.unique_integer([:positive])}.bak"
        )

      assert {:ok, _} = SafetyCheck.create_backup(m)
    end

    test "creates backup from existing target file" do
      tmp_dir = System.tmp_dir!()
      unique = :erlang.unique_integer([:positive])
      target = Path.join(tmp_dir, "sc_target_#{unique}.json")
      backup = Path.join(tmp_dir, "sc_backup_#{unique}.bak")

      File.write!(target, "original content")

      try do
        m = build_migration(target_path: target, backup_path: backup)
        assert {:ok, _} = SafetyCheck.create_backup(m)
        assert File.exists?(backup)
        assert File.read!(backup) == "original content"
      after
        File.rm(target)
        File.rm(backup)
      end
    end

    test "refuses to overwrite existing backup without force" do
      tmp_dir = System.tmp_dir!()
      unique = :erlang.unique_integer([:positive])
      target = Path.join(tmp_dir, "sc_target_#{unique}.json")
      backup = Path.join(tmp_dir, "sc_backup_#{unique}.bak")

      File.write!(target, "new content")
      File.write!(backup, "old backup")

      try do
        m = build_migration(target_path: target, backup_path: backup, force: false)
        assert {:error, {:backup_already_exists, ^backup}} = SafetyCheck.create_backup(m)
        assert File.read!(backup) == "old backup"
      after
        File.rm(target)
        File.rm(backup)
      end
    end

    test "overwrites existing backup with force" do
      tmp_dir = System.tmp_dir!()
      unique = :erlang.unique_integer([:positive])
      target = Path.join(tmp_dir, "sc_target_#{unique}.json")
      backup = Path.join(tmp_dir, "sc_backup_#{unique}.bak")

      File.write!(target, "new content")
      File.write!(backup, "old backup")

      try do
        m = build_migration(target_path: target, backup_path: backup, force: true)
        assert {:ok, _} = SafetyCheck.create_backup(m)
        assert File.read!(backup) == "new content"
      after
        File.rm(target)
        File.rm(backup)
      end
    end
  end

  # ── Warnings ────────────────────────────────────────────────────────────

  describe "warnings/1" do
    test "includes serialized data warnings" do
      m =
        build_migration(
          items: [%{key: "evil", value: "%{__struct__: Bad, data: :stuff}"}],
          warnings: [],
          raw_warnings: []
        )

      warnings = SafetyCheck.warnings(m)
      assert Enum.any?(warnings, &String.contains?(&1, "serialized data"))
    end

    test "includes raw legacy warnings" do
      m = build_migration(raw_warnings: ["Unknown key 'sketchy' contains serialized data"])

      warnings = SafetyCheck.warnings(m)
      assert Enum.any?(warnings, &String.contains?(&1, "sketchy"))
    end

    test "includes backup warning in execute mode without backup" do
      m = build_migration(mode: :execute, backup_path: nil, raw_warnings: [])

      warnings = SafetyCheck.warnings(m)
      assert Enum.any?(warnings, &String.contains?(&1, "Backup"))
    end

    test "no backup warning in dry_run mode" do
      m = build_migration(mode: :dry_run, backup_path: nil, raw_warnings: [])

      warnings = SafetyCheck.warnings(m)
      refute Enum.any?(warnings, &String.contains?(&1, "Backup"))
    end

    test "no backup warning when backup exists in execute mode" do
      tmp_path =
        System.tmp_dir!()
        |> Path.join("migration_backup_warn_test_#{:erlang.unique_integer([:positive])}.bak")

      File.write!(tmp_path, "backup data")

      try do
        m = build_migration(mode: :execute, backup_path: tmp_path, raw_warnings: [])

        warnings = SafetyCheck.warnings(m)
        refute Enum.any?(warnings, &String.contains?(&1, "Backup"))
      after
        File.rm(tmp_path)
      end
    end
  end

  # ── Safety gates ────────────────────────────────────────────────────────

  describe "safe_to_dry_run?/1" do
    test "true for dry_run with clean data" do
      m = build_migration(mode: :dry_run, items: [%{key: "model", value: "gpt-4"}])
      assert SafetyCheck.safe_to_dry_run?(m)
    end

    test "false for dry_run with unsafe serialized data in items" do
      m =
        build_migration(
          mode: :dry_run,
          items: [%{key: "evil", value: "%{__struct__: Bad}"}]
        )

      refute SafetyCheck.safe_to_dry_run?(m)
    end

    test "false for dry_run with raw legacy warnings" do
      m = build_migration(mode: :dry_run, raw_warnings: ["Dangerous unknown key"])
      refute SafetyCheck.safe_to_dry_run?(m)
    end

    test "false for non-dry_run mode" do
      m = build_migration(mode: :execute)
      refute SafetyCheck.safe_to_dry_run?(m)
    end
  end

  describe "safe_to_execute?/1" do
    test "false for dry_run mode (use safe_to_dry_run? instead)" do
      m = build_migration(mode: :dry_run)
      refute SafetyCheck.safe_to_execute?(m)
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
            warnings: [],
            raw_warnings: []
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
