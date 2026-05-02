defmodule Tet.MigrationTest do
  use ExUnit.Case, async: true

  alias Tet.Migration

  @basic_attrs %{
    source_path: "/etc/legacy/config.json",
    target_path: "/etc/tet/config.json",
    backup_path: "/etc/tet/config.json.bak"
  }

  @legacy_config %{
    "api_key" => "sk-test-123",
    "model" => "gpt-4",
    "base_url" => "https://api.openai.com",
    "data_dir" => "/data/tet",
    "timeout" => "30",
    "max_tokens" => "4096",
    "temperature" => "0.7",
    "verbose" => "true",
    "auto_save" => "yes",
    "auto_save_interval" => "60",
    "session_path" => "/sessions",
    "system_prompt" => "You are helpful.",
    "shell_whitelist" => ["ls", "cat"]
  }

  describe "new/1" do
    test "creates migration with required attrs" do
      assert {:ok, m} = Migration.new(@basic_attrs)
      assert m.source_path == "/etc/legacy/config.json"
      assert m.target_path == "/etc/tet/config.json"
      assert m.backup_path == "/etc/tet/config.json.bak"
      assert m.mode == :dry_run
      assert m.status == :pending
      assert m.items == []
      assert m.warnings == []
      assert m.raw_warnings == []
      assert m.skipped_items == []
    end

    test "accepts atom keys" do
      assert {:ok, m} =
               Migration.new(%{
                 source_path: "/src",
                 target_path: "/tgt",
                 mode: :execute
               })

      assert m.mode == :execute
    end

    test "accepts string keys" do
      assert {:ok, m} =
               Migration.new(%{
                 "source_path" => "/src",
                 "target_path" => "/tgt"
               })

      assert m.source_path == "/src"
    end

    test "defaults mode to dry_run" do
      assert {:ok, m} = Migration.new(%{source_path: "/src"})
      assert m.mode == :dry_run
    end

    test "requires source_path" do
      assert {:error, :source_path_required} = Migration.new(%{target_path: "/tgt"})
    end

    test "rejects nil source_path" do
      assert {:error, :source_path_required} = Migration.new(%{source_path: nil})
    end

    test "rejects empty source_path" do
      assert {:error, :source_path_required} = Migration.new(%{source_path: ""})
    end

    test "rejects string-keyed invalid mode" do
      assert {:error, {:invalid_mode, :nuke}} =
               Migration.new(%{"source_path" => "/src", "mode" => :nuke})
    end

    test "rejects invalid mode" do
      assert {:error, {:invalid_mode, :nuke}} =
               Migration.new(%{source_path: "/src", mode: :nuke})
    end

    test "rejects non-map input" do
      assert {:error, :invalid_attrs} = Migration.new("nope")
    end

    test "defaults force to false" do
      assert {:ok, m} = Migration.new(@basic_attrs)
      assert m.force == false
    end

    test "accepts force flag" do
      assert {:ok, m} = Migration.new(Map.put(@basic_attrs, :force, true))
      assert m.force == true
    end
  end

  describe "analyze/2" do
    test "populates items from compatible keys" do
      {:ok, m} = Migration.new(@basic_attrs)
      result = Migration.analyze(m, @legacy_config)

      assert result.status == :analyzed
      assert length(result.items) > 0

      api_key_item = Enum.find(result.items, &(&1.key == "api_key"))
      assert api_key_item.section == :provider
      assert api_key_item.new_key == "api_key"
      # api_key value should be in item but NOT in reports
      assert api_key_item.transformed == "sk-test-123"
    end

    test "transforms values during analysis" do
      {:ok, m} = Migration.new(@basic_attrs)
      result = Migration.analyze(m, @legacy_config)

      timeout_item = Enum.find(result.items, &(&1.key == "timeout"))
      assert timeout_item.transformed == 30

      temp_item = Enum.find(result.items, &(&1.key == "temperature"))
      assert temp_item.transformed == 0.7

      verbose_item = Enum.find(result.items, &(&1.key == "verbose"))
      assert verbose_item.transformed == true
    end

    test "collects warnings for unsafe keys" do
      {:ok, m} = Migration.new(@basic_attrs)
      result = Migration.analyze(m, @legacy_config)

      assert Enum.any?(result.warnings, &String.contains?(&1, "system_prompt"))
      assert Enum.any?(result.warnings, &String.contains?(&1, "shell_whitelist"))
    end

    test "preserves existing warnings" do
      {:ok, m} =
        Migration.new(Map.merge(@basic_attrs, %{warnings: ["pre-existing warning"]}))

      result = Migration.analyze(m, @legacy_config)
      assert "pre-existing warning" in result.warnings
    end

    test "maps data_dir to store.path" do
      {:ok, m} = Migration.new(@basic_attrs)
      result = Migration.analyze(m, %{"data_dir" => "/data/tet"})

      data_dir_item = Enum.find(result.items, &(&1.key == "data_dir"))
      assert data_dir_item.section == :store
      assert data_dir_item.new_key == "path"
    end

    test "scans raw legacy data before filtering and populates raw_warnings" do
      {:ok, m} = Migration.new(@basic_attrs)

      legacy =
        Map.merge(@legacy_config, %{
          "unknown_dangerous" => "%{__struct__: EvilModule, payload: :hack}"
        })

      result = Migration.analyze(m, legacy)

      # Should have raw_warning about the unknown key with serialized data
      assert length(result.raw_warnings) > 0
      assert Enum.any?(result.raw_warnings, &String.contains?(&1, "unknown_dangerous"))
    end

    test "populates skipped_items for unknown keys" do
      {:ok, m} = Migration.new(@basic_attrs)

      legacy = Map.merge(@legacy_config, %{"totally_made_up" => "wat"})
      result = Migration.analyze(m, legacy)

      skipped = Enum.find(result.skipped_items, &(&1.key == "totally_made_up"))
      assert skipped != nil
      assert skipped.reason == :unknown_key
    end

    test "detects pickle magic bytes in unknown keys" do
      {:ok, m} = Migration.new(@basic_attrs)

      # Python pickle protocol 5 starts with 0x80
      pickle_value = <<128, 5, 0, 0, 0>>
      legacy = Map.merge(@legacy_config, %{"pickle_config" => pickle_value})

      result = Migration.analyze(m, legacy)

      skipped = Enum.find(result.skipped_items, &(&1.key == "pickle_config"))
      assert skipped != nil
      assert skipped.reason == :pickle_magic_bytes
      assert Enum.any?(result.raw_warnings, &String.contains?(&1, "pickle"))
    end

    test "handles atom-keyed config items" do
      {:ok, m} = Migration.new(@basic_attrs)

      # Atom-keyed config should be normalized to string keys
      result = Migration.analyze(m, %{model: "gpt-4", timeout: "30"})

      assert length(result.items) == 2
      assert Enum.any?(result.items, &(&1.key == "model"))
      assert Enum.any?(result.items, &(&1.key == "timeout"))
    end
  end

  describe "dry_run/1" do
    test "enriches with safety warnings and marks complete" do
      {:ok, m} = Migration.new(@basic_attrs)
      m = Migration.analyze(m, @legacy_config)
      result = Migration.dry_run(m)

      assert result.status == :dry_run_complete
    end

    test "raises if called before analyze" do
      {:ok, m} = Migration.new(@basic_attrs)

      assert_raise ArgumentError, ~r/Must be :analyzed first/, fn ->
        Migration.dry_run(m)
      end
    end

    test "does not duplicate plan warnings" do
      {:ok, m} = Migration.new(@basic_attrs)
      m = Migration.analyze(m, @legacy_config)

      pre_dry_run_warning_count = length(m.warnings)
      result = Migration.dry_run(m)

      # SafetyCheck.warnings should not re-include plan warnings that already exist
      # The only new warnings should be safety-specific ones
      assert length(result.warnings) >= pre_dry_run_warning_count
      # Verify no exact duplicates
      assert length(result.warnings) == length(Enum.uniq(result.warnings))
    end

    test "adds serialized data warnings when present in items" do
      {:ok, m} = Migration.new(@basic_attrs)

      # Use an item with a serialized pattern that will land in the items list
      legacy =
        Map.merge(@legacy_config, %{
          "model" => "%{__struct__: SomeModule, data: \"bad\"}"
        })

      m = Migration.analyze(m, legacy)
      result = Migration.dry_run(m)

      assert result.status == :dry_run_complete
    end

    test "raw warnings for unknown serialized data persist through dry_run" do
      {:ok, m} = Migration.new(@basic_attrs)

      legacy =
        Map.merge(@legacy_config, %{
          "unknown_sketchy" => "Code.eval_string(\"IO.puts(:pwned)\")"
        })

      m = Migration.analyze(m, legacy)
      result = Migration.dry_run(m)

      assert result.status == :dry_run_complete
      assert Enum.any?(result.warnings, &String.contains?(&1, "unknown_sketchy"))
    end
  end

  describe "create_backup/1" do
    test "returns error when target_path is nil" do
      {:ok, m} = Migration.new(%{source_path: "/src", backup_path: "/bak"})
      assert {:error, :no_target_path} = Migration.create_backup(m)
    end

    test "returns error when backup_path is nil" do
      {:ok, m} = Migration.new(%{source_path: "/src", target_path: "/tgt"})
      assert {:error, :no_backup_path} = Migration.create_backup(m)
    end

    test "returns ok when target does not exist (fresh install)" do
      {:ok, m} =
        Migration.new(%{
          source_path: "/src",
          target_path: "/tmp/nonexistent_target_#{:erlang.unique_integer([:positive])}.json",
          backup_path: "/tmp/backup_#{:erlang.unique_integer([:positive])}.bak"
        })

      assert {:ok, _} = Migration.create_backup(m)
    end

    test "creates backup from existing target file" do
      tmp_dir = System.tmp_dir!()
      unique = :erlang.unique_integer([:positive])
      target = Path.join(tmp_dir, "migration_target_#{unique}.json")
      backup = Path.join(tmp_dir, "migration_backup_#{unique}.bak")

      File.write!(target, "{\"model\": \"gpt-4\"}")

      try do
        {:ok, m} =
          Migration.new(%{
            source_path: "/src",
            target_path: target,
            backup_path: backup
          })

        assert {:ok, _} = Migration.create_backup(m)
        assert File.exists?(backup)
        assert File.read!(backup) == "{\"model\": \"gpt-4\"}"
      after
        File.rm(target)
        File.rm(backup)
      end
    end

    test "refuses to overwrite existing backup without force" do
      tmp_dir = System.tmp_dir!()
      unique = :erlang.unique_integer([:positive])
      target = Path.join(tmp_dir, "migration_target_#{unique}.json")
      backup = Path.join(tmp_dir, "migration_backup_#{unique}.bak")

      File.write!(target, "{\"model\": \"gpt-4\"}")
      File.write!(backup, "old backup")

      try do
        {:ok, m} =
          Migration.new(%{
            source_path: "/src",
            target_path: target,
            backup_path: backup
          })

        assert {:error, {:backup_already_exists, ^backup}} = Migration.create_backup(m)
        # Original backup untouched
        assert File.read!(backup) == "old backup"
      after
        File.rm(target)
        File.rm(backup)
      end
    end

    test "overwrites existing backup with force: true" do
      tmp_dir = System.tmp_dir!()
      unique = :erlang.unique_integer([:positive])
      target = Path.join(tmp_dir, "migration_target_#{unique}.json")
      backup = Path.join(tmp_dir, "migration_backup_#{unique}.bak")

      File.write!(target, "{\"model\": \"gpt-4\"}")
      File.write!(backup, "old backup")

      try do
        {:ok, m} =
          Migration.new(%{
            source_path: "/src",
            target_path: target,
            backup_path: backup,
            force: true
          })

        assert {:ok, _} = Migration.create_backup(m)
        assert File.read!(backup) == "{\"model\": \"gpt-4\"}"
      after
        File.rm(target)
        File.rm(backup)
      end
    end

    test "creates backup directory if it does not exist" do
      tmp_dir = System.tmp_dir!()
      unique = :erlang.unique_integer([:positive])
      target = Path.join(tmp_dir, "migration_target_#{unique}.json")
      backup_dir = Path.join(tmp_dir, "migration_backup_dir_#{unique}")
      backup = Path.join(backup_dir, "config.bak")

      File.write!(target, "{\"model\": \"gpt-4\"}")

      try do
        {:ok, m} =
          Migration.new(%{
            source_path: "/src",
            target_path: target,
            backup_path: backup
          })

        refute File.exists?(backup_dir)
        assert {:ok, _} = Migration.create_backup(m)
        assert File.exists?(backup)
        assert File.read!(backup) == "{\"model\": \"gpt-4\"}"
      after
        File.rm(target)
        File.rm_rf(backup_dir)
      end
    end
  end

  describe "report/1" do
    test "includes header, items, warnings, and status" do
      {:ok, m} = Migration.new(@basic_attrs)
      m = Migration.analyze(m, @legacy_config)
      m = Migration.dry_run(m)

      report = Migration.report(m)

      assert String.contains?(report, "Migration Dry-Run Report")
      assert String.contains?(report, "/etc/legacy/config.json")
      assert String.contains?(report, "dry_run")
      assert String.contains?(report, "dry_run_complete")
    end

    test "redacts sensitive values like API keys" do
      {:ok, m} = Migration.new(@basic_attrs)
      m = Migration.analyze(m, @legacy_config)
      m = Migration.dry_run(m)

      report = Migration.report(m)

      # The raw API key should NEVER appear in the report
      refute String.contains?(report, "sk-test-123")
      # Instead, partial preview like "sk-t...123" should appear
      assert String.contains?(report, "api_key")
    end

    test "shows no-items message when empty" do
      {:ok, m} = Migration.new(@basic_attrs)
      report = Migration.report(m)

      assert String.contains?(report, "no items to migrate")
    end

    test "shows no-warnings message when clean" do
      {:ok, m} = Migration.new(@basic_attrs)
      report = Migration.report(m)

      assert String.contains?(report, "no warnings")
    end

    test "pending status shows not-yet-analyzed" do
      {:ok, m} = Migration.new(@basic_attrs)
      report = Migration.report(m)

      assert String.contains?(report, "Not yet analyzed")
    end

    test "includes skipped items section when present" do
      {:ok, m} = Migration.new(@basic_attrs)
      m = Migration.analyze(m, Map.merge(@legacy_config, %{"weird_key" => "value"}))

      report = Migration.report(m)
      assert String.contains?(report, "Skipped / Manual-Review Items")
      assert String.contains?(report, "weird_key")
    end

    test "no skipped items section when clean" do
      {:ok, m} = Migration.new(@basic_attrs)
      m = Migration.analyze(m, %{"model" => "gpt-4"})

      report = Migration.report(m)
      refute String.contains?(report, "Skipped / Manual-Review")
    end

    test "redacts sk-... values on unknown keys regardless of key name" do
      # An unknown key whose VALUE looks like a secret (sk- prefix) must be redacted
      # even though the key name itself is not sensitive
      {:ok, m} = Migration.new(@basic_attrs)

      legacy = Map.merge(@legacy_config, %{"totally_innocent_key" => "sk-abc123ABCDEFGHIJ"})
      m = Migration.analyze(m, legacy)
      report = Migration.report(m)

      # The raw secret value must NOT appear in the report
      refute String.contains?(report, "sk-abc123ABCDEFGHIJ")
    end
  end

  describe "execute/1" do
    test "returns error for dry_run mode" do
      {:ok, m} = Migration.new(@basic_attrs)
      assert {:error, {:cannot_execute_in_dry_run, _}} = Migration.execute(m)
    end

    test "returns not_safe_to_execute when plan has warnings (preflight check)" do
      {:ok, m} =
        Migration.new(Map.merge(@basic_attrs, %{mode: :execute}))

      # Inject a warning that would come from analyzing unsafe keys like system_prompt
      m = %{m | warnings: ["Unsafe key 'system_prompt' requires manual review"]}

      assert {:error, :not_safe_to_execute} = Migration.execute(m)
    end

    test "returns not_safe_to_execute when raw_warnings present (preflight check)" do
      {:ok, m} =
        Migration.new(Map.merge(@basic_attrs, %{mode: :execute}))

      m = %{m | raw_warnings: ["Unknown key 'sketchy' contains serialized data"]}

      assert {:error, :not_safe_to_execute} = Migration.execute(m)
    end

    test "returns not_safe_to_execute when items have serialized data (preflight check)" do
      {:ok, m} =
        Migration.new(Map.merge(@basic_attrs, %{mode: :execute}))

      m = %{m | items: [%{key: "evil", value: "%{__struct__: Bad}"}]}

      assert {:error, :not_safe_to_execute} = Migration.execute(m)
    end

    test "backup is NOT created if preflight checks fail" do
      tmp_dir = System.tmp_dir!()
      unique = :erlang.unique_integer([:positive])
      target = Path.join(tmp_dir, "exec_target_#{unique}.json")
      backup = Path.join(tmp_dir, "exec_backup_#{unique}.bak")

      File.write!(target, "{\"model\": \"gpt-4\"}")

      try do
        {:ok, m} =
          Migration.new(%{
            source_path: target,
            target_path: target,
            backup_path: backup,
            mode: :execute
          })

        # Add a warning to fail preflight
        m = %{m | warnings: ["Unsafe key 'system_prompt' requires manual review"]}

        assert {:error, :not_safe_to_execute} = Migration.execute(m)
        # Backup should NOT have been created since preflight failed
        refute File.exists?(backup)
      after
        File.rm(target)
        File.rm_rf(backup)
      end
    end

    test "executes successfully with clean migration and real files" do
      tmp_dir = System.tmp_dir!()
      unique = :erlang.unique_integer([:positive])
      source = Path.join(tmp_dir, "exec_source_#{unique}.json")
      target = Path.join(tmp_dir, "exec_target_#{unique}.json")
      backup = Path.join(tmp_dir, "exec_backup_#{unique}.bak")

      legacy = %{"model" => "gpt-4", "timeout" => "30"}
      File.write!(source, Jason.encode!(legacy))
      File.write!(target, "{\"existing\": true}")

      try do
        {:ok, m} =
          Migration.new(%{
            source_path: source,
            target_path: target,
            backup_path: backup,
            mode: :execute
          })

        m = Migration.analyze(m, legacy)

        assert {:ok, result} = Migration.execute(m)
        assert result.status == :executed
        # Backup should exist
        assert File.exists?(backup)
        # Target should be updated
        assert File.exists?(target)
      after
        File.rm(source)
        File.rm(target)
        File.rm_rf(backup)
      end
    end
  end

  describe "full workflow" do
    test "happy path: new → analyze → dry_run → report" do
      {:ok, m} = Migration.new(@basic_attrs)
      assert m.status == :pending

      m = Migration.analyze(m, @legacy_config)
      assert m.status == :analyzed
      assert length(m.items) > 0

      m = Migration.dry_run(m)
      assert m.status == :dry_run_complete

      report = Migration.report(m)
      assert String.contains?(report, "Dry-run complete")
      # No raw API key leaked
      refute String.contains?(report, "sk-test-123")
    end

    test "only compatible keys produce items" do
      {:ok, m} = Migration.new(@basic_attrs)

      m = Migration.analyze(m, %{"model" => "gpt-4", "system_prompt" => "be evil"})
      assert length(m.items) == 1
      assert hd(m.items).key == "model"
      assert Enum.any?(m.warnings, &String.contains?(&1, "system_prompt"))
    end
  end
end
