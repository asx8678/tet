defmodule Tet.Migration do
  @moduledoc """
  Settings migration dry-run workflow — BD-0072.

  Migrates legacy CLI config into the new Tet config structure. By default
  runs in `:dry_run` mode which simulates changes without touching files.
  Use `:execute` mode only after `safe_to_execute?/1` returns true.
  """

  alias Tet.Migration.ConfigMapper
  alias Tet.Migration.SafetyCheck

  @type mode :: :dry_run | :execute
  @type status :: :pending | :analyzed | :dry_run_complete | :executed | :failed

  @type t :: %__MODULE__{
          source_path: Path.t() | nil,
          target_path: Path.t() | nil,
          backup_path: Path.t() | nil,
          mode: mode(),
          force: boolean(),
          items: [map()],
          warnings: [binary()],
          raw_warnings: [binary()],
          skipped_items: [map()],
          status: status()
        }

  defstruct [
    :source_path,
    :target_path,
    :backup_path,
    mode: :dry_run,
    force: false,
    items: [],
    warnings: [],
    raw_warnings: [],
    skipped_items: [],
    status: :pending
  ]

  @valid_modes [:dry_run, :execute]
  # ── Construction ──────────────────────────────────────────────────────────

  @doc """
  Validates attrs and creates a new Migration struct.

  Accepts both atom and string keys. Defaults mode to `:dry_run` and status
  to `:pending`. String-keyed mode values are validated the same as atom keys.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with :ok <- validate_source(attrs),
         :ok <- validate_mode(attrs) do
      migration = %__MODULE__{
        source_path: get_attr(attrs, :source_path),
        target_path: get_attr(attrs, :target_path),
        backup_path: get_attr(attrs, :backup_path),
        mode: get_attr(attrs, :mode, :dry_run),
        force: get_attr(attrs, :force, false),
        items: get_attr(attrs, :items, []),
        warnings: get_attr(attrs, :warnings, []),
        raw_warnings: get_attr(attrs, :raw_warnings, []),
        skipped_items: get_attr(attrs, :skipped_items, []),
        status: get_attr(attrs, :status, :pending)
      }

      {:ok, migration}
    end
  end

  def new(_), do: {:error, :invalid_attrs}

  # ── Analysis ──────────────────────────────────────────────────────────────

  @doc """
  Analyzes a legacy config map and populates migration items.

  Safety scanning happens on the RAW legacy input BEFORE key filtering, so
  unknown keys with dangerous content (pickle bytes, Code.eval_string) are
  caught as raw_warnings and skipped_items rather than silently dropped.

  Each item is a map with `:key`, `:value`, `:section`, `:new_key`, and
  `:transformed` fields. Unsafe keys are added to warnings.
  """
  @spec analyze(t(), map()) :: t()
  def analyze(%__MODULE__{} = migration, legacy_config) when is_map(legacy_config) do
    # 1. Scan ALL raw key/value pairs BEFORE any mapping/filtering
    {raw_warnings, skipped_items} = SafetyCheck.check_raw_legacy_data(legacy_config)

    # 2. Map config — compatible keys get mapped, unsafe keys collected
    {:ok, mapped, unsafe_found, _unknown_found} = ConfigMapper.map_config(legacy_config)

    # 3. Build items only from compatible keys
    items = build_items(legacy_config, mapped)

    # 4. Merge warnings
    unsafe_warnings =
      unsafe_found
      |> Enum.map(&"Unsafe key '#{&1}' requires manual review")

    all_warnings =
      migration.warnings ++
        unsafe_warnings

    %{
      migration
      | items: items,
        warnings: all_warnings,
        raw_warnings: raw_warnings,
        skipped_items: skipped_items,
        status: :analyzed
    }
  end

  # ── Dry Run ──────────────────────────────────────────────────────────────

  @doc """
  Simulates the migration without writing any files.

  Adds safety warnings from `SafetyCheck` and sets status to
  `:dry_run_complete`. Returns the migration struct enriched with
  what-would-change info.

  Backup warnings are excluded during dry-run since backup creation
  is part of the execute flow, not the dry-run simulation.
  """
  @spec dry_run(t()) :: t()
  def dry_run(%__MODULE__{status: :analyzed} = migration) do
    # Only add warnings that aren't already present (avoids duplication)
    safety_warnings = SafetyCheck.warnings(migration)

    existing_set = MapSet.new(migration.warnings)

    # Filter out backup warnings — they are a concern of the execute flow,
    # not the dry-run simulation. Backup is created as part of execute.
    backup_warning_prefix = "Backup must be created"

    new_warnings =
      safety_warnings
      |> Enum.reject(&MapSet.member?(existing_set, &1))
      |> Enum.reject(&String.starts_with?(&1, backup_warning_prefix))

    all_warnings = migration.warnings ++ new_warnings

    %{migration | warnings: all_warnings, status: :dry_run_complete}
  end

  def dry_run(%__MODULE__{status: status}) do
    raise ArgumentError, "Cannot dry_run from status #{inspect(status)}. Must be :analyzed first."
  end

  # ── Backup ────────────────────────────────────────────────────────────────

  @doc """
  Creates a backup of the current target config file before migration.

  Requires both `target_path` and `backup_path` to be set. Creates the
  backup directory if needed and copies the current file. Will not overwrite
  an existing backup unless `force: true` is set on the migration.

  Returns `{:ok, migration}` on success or `{:error, reason}` on failure.
  """
  @spec create_backup(t()) :: {:ok, t()} | {:error, term()}
  def create_backup(%__MODULE__{target_path: nil}), do: {:error, :no_target_path}
  def create_backup(%__MODULE__{backup_path: nil}), do: {:error, :no_backup_path}

  def create_backup(
        %__MODULE__{target_path: target, backup_path: backup, force: force} = migration
      ) do
    cond do
      not File.exists?(target) ->
        # Nothing to back up — that's ok (fresh install)
        {:ok, migration}

      File.exists?(backup) and not force ->
        {:error, {:backup_already_exists, backup}}

      true ->
        backup
        |> Path.dirname()
        |> File.mkdir_p()
        |> case do
          :ok ->
            case File.cp(target, backup) do
              :ok -> {:ok, migration}
              {:error, reason} -> {:error, {:backup_copy_failed, reason}}
            end

          {:error, reason} ->
            {:error, {:backup_dir_failed, reason}}
        end
    end
  end

  # ── Execute ──────────────────────────────────────────────────────────────

  @doc """
  Executes the migration after all safety checks pass.

  Requires a successful backup and `safe_to_execute?/1` returning true.

  **Dry-run-first safety:** The migration must have completed a dry run
  (status `:dry_run_complete`) before execution is allowed. This prevents
  accidental execution without reviewing what would change.

  **Rollback support:** If the target write fails after a backup has been
  created, the backup is automatically restored to the target path and the
  error is wrapped with `{:rolled_back, original_reason}`.

  Error reasons:
  - `{:cannot_execute_in_dry_run, t()}` — mode is `:dry_run`
  - `{:dry_run_not_completed, t()}` — status is not `:dry_run_complete`
  - `:not_safe_to_execute` — preflight safety checks failed
  - `{:execute_failed, term()}` — I/O error during read or write
  - `{:execute_failed, {:rolled_back, term()}}` — write failed and backup was restored
  """
  @spec execute(t()) :: {:ok, t()} | {:error, term()}
  def execute(%__MODULE__{mode: :dry_run} = migration) do
    {:error, {:cannot_execute_in_dry_run, %{migration | status: :failed}}}
  end

  def execute(%__MODULE__{mode: :execute, status: status} = migration)
      when status != :dry_run_complete do
    {:error, {:dry_run_not_completed, %{migration | status: :failed}}}
  end

  def execute(%__MODULE__{mode: :execute, status: :dry_run_complete} = migration) do
    with :ok <- preflight_checks(migration),
         {:ok, migration} <- create_backup(migration),
         true <- SafetyCheck.safe_to_execute?(migration),
         {:ok, legacy_config} <- read_legacy_config(migration),
         {:ok, mapped, _unsafe, _unknown} <- ConfigMapper.map_config(legacy_config) do
      case write_target_config(migration, mapped) do
        :ok ->
          {:ok, %{migration | status: :executed}}

        {:error, reason} ->
          case rollback_from_backup(%{migration | status: :failed}) do
            :ok ->
              {:error, {:execute_failed, {:rolled_back, reason}}}

            {:error, _rollback_error} ->
              {:error, {:execute_failed, {:rolled_back_failed, reason}}}
          end
      end
    else
      false -> {:error, :not_safe_to_execute}
      {:error, reason} -> {:error, {:execute_failed, reason}}
    end
  end

  defp preflight_checks(migration) do
    cond do
      SafetyCheck.check_serialized_data(migration) != [] -> false
      migration.raw_warnings != [] -> false
      migration.warnings != [] -> false
      true -> :ok
    end
  end

  @doc """
  Restores the target config file from a previously created backup.

  Used by the execute flow to automatically roll back when the target write
  fails after backup creation. Returns `:ok` on successful rollback or
  `{:error, reason}` if the rollback itself fails.
  """
  @spec rollback_from_backup(t()) :: :ok | {:error, term()}
  def rollback_from_backup(%__MODULE__{backup_path: nil}), do: {:error, :no_backup_path}
  def rollback_from_backup(%__MODULE__{target_path: nil}), do: {:error, :no_target_path}

  def rollback_from_backup(%__MODULE__{target_path: target, backup_path: backup}) do
    cond do
      not File.exists?(backup) ->
        {:error, {:backup_not_found, backup}}

      not File.exists?(target) ->
        # Target was deleted or never existed — copy backup into place
        case File.cp(backup, target) do
          :ok -> :ok
          {:error, reason} -> {:error, {:rollback_cp_failed, reason}}
        end

      true ->
        # Both exist — overwrite target with backup contents
        case File.read(backup) do
          {:ok, content} ->
            case File.write(target, content) do
              :ok -> :ok
              {:error, reason} -> {:error, {:rollback_write_failed, reason}}
            end

          {:error, reason} ->
            {:error, {:rollback_read_failed, reason}}
        end
    end
  end

  # ── Report ───────────────────────────────────────────────────────────────

  @doc """
  Generates a human-readable report of the migration dry-run.

  Shows items that would be migrated, warnings, and overall safety status.
  Sensitive values (API keys, tokens) are redacted in the output.
  """
  @spec report(t()) :: binary()
  def report(%__MODULE__{} = migration) do
    lines = [
      header_line(migration),
      item_lines(migration),
      skipped_lines(migration),
      warning_lines(migration),
      status_line(migration)
    ]

    lines
    |> List.flatten()
    |> Enum.join("\n")
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp validate_source(%{source_path: sp}) when is_binary(sp) and byte_size(sp) > 0, do: :ok
  defp validate_source(%{"source_path" => sp}) when is_binary(sp) and byte_size(sp) > 0, do: :ok

  defp validate_source(%{source_path: _}), do: {:error, :source_path_required}
  defp validate_source(%{"source_path" => _}), do: {:error, :source_path_required}

  defp validate_source(attrs) do
    if Map.has_key?(attrs, :source_path) or Map.has_key?(attrs, "source_path") do
      {:error, :source_path_required}
    else
      {:error, :source_path_required}
    end
  end

  defp validate_mode(%{mode: mode}) when mode in @valid_modes, do: :ok
  defp validate_mode(%{mode: mode}), do: {:error, {:invalid_mode, mode}}

  defp validate_mode(%{"mode" => mode}) when mode in @valid_modes, do: :ok
  defp validate_mode(%{"mode" => mode}), do: {:error, {:invalid_mode, mode}}

  defp validate_mode(_attrs), do: :ok

  defp get_attr(attrs, key, default \\ nil) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key), default)
  end

  defp build_items(legacy_config, mapped) do
    compatible = ConfigMapper.compatible_keys()

    # Normalize legacy config keys to strings for consistent lookup
    normalized = normalize_config(legacy_config)

    compatible
    |> Enum.filter(&Map.has_key?(normalized, &1))
    |> Enum.map(fn key ->
      value = normalized[key]
      {section, new_key} = ConfigMapper.compatible_mapping(key)
      transformed = ConfigMapper.transform_value(key, value)

      %{
        key: key,
        value: value,
        section: section,
        new_key: new_key,
        transformed: transformed,
        target:
          mapped[Atom.to_string(section)] &&
            mapped[Atom.to_string(section)][new_key]
      }
    end)
  end

  # Normalize atom-keyed config to string keys
  defp normalize_config(config) do
    Enum.reduce(config, %{}, fn
      {key, value}, acc when is_atom(key) ->
        Map.put(acc, Atom.to_string(key), value)

      {key, value}, acc when is_binary(key) ->
        Map.put(acc, key, value)

      {_key, _value}, acc ->
        acc
    end)
  end

  defp header_line(migration) do
    [
      "═══ Migration Dry-Run Report ═══",
      "Source:   #{migration.source_path || "(not set)"}",
      "Target:   #{migration.target_path || "(not set)"}",
      "Backup:   #{migration.backup_path || "(not set)"}",
      "Mode:     #{migration.mode}",
      "Status:   #{migration.status}",
      "Items:    #{length(migration.items)}",
      "Warnings: #{length(migration.warnings)}",
      ""
    ]
  end

  defp item_lines(%__MODULE__{items: []}), do: ["  (no items to migrate)", ""]

  defp item_lines(%__MODULE__{items: items}) do
    item_lines =
      Enum.map(items, fn item ->
        safe_transformed = redact_value(item.key, item.transformed)
        "  #{item.key} → #{item.section}.#{item.new_key} = #{inspect(safe_transformed)}"
      end)

    ["── Items ──"] ++ item_lines ++ [""]
  end

  defp skipped_lines(%__MODULE__{skipped_items: []}), do: []

  defp skipped_lines(%__MODULE__{skipped_items: skipped}) do
    lines =
      Enum.map(skipped, fn item ->
        safe_value = redact_value(item.key, item.value)
        "  #{item.key} = #{inspect(safe_value)} (unknown key — manual review)"
      end)

    ["── Skipped / Manual-Review Items ──"] ++ lines ++ [""]
  end

  defp warning_lines(%__MODULE__{warnings: []}), do: ["  (no warnings)", ""]

  defp warning_lines(%__MODULE__{warnings: warnings}) do
    warning_lines =
      Enum.map(warnings, fn w ->
        "  ⚠  #{redact_warning_string(w)}"
      end)

    ["── Warnings ──"] ++ warning_lines ++ [""]
  end

  defp redact_warning_string(warning) when is_binary(warning) do
    # Replace any secret-looking tokens in the warning string
    Regex.replace(
      ~r/(sk-|pk-|Bearer |token-|key-|ghp_|gho_|github_pat_|AKIA)[A-Za-z0-9_\-]{4,}/i,
      warning,
      fn match, _prefix ->
        prefix = String.slice(match, 0, 4)
        suffix = String.slice(match, -4, 4)
        "#{prefix}...#{suffix}"
      end
    )
  end

  defp redact_warning_string(other), do: inspect(other)

  defp status_line(%__MODULE__{mode: :dry_run, status: :dry_run_complete}) do
    "✓ Dry-run complete. Review warnings above before executing."
  end

  defp status_line(%__MODULE__{mode: :execute} = m) do
    if SafetyCheck.safe_to_execute?(m), do: "✓ Safe to execute.", else: "✗ NOT safe to execute."
  end

  defp status_line(%__MODULE__{status: :pending}), do: "⏳ Not yet analyzed."
  defp status_line(%__MODULE__{status: :analyzed}), do: "⏳ Analyzed — call dry_run/1 next."
  defp status_line(%__MODULE__{status: :executed}), do: "✓ Migration executed."
  defp status_line(%__MODULE__{status: :failed}), do: "✗ Migration failed."

  # Redact sensitive values before placing in reports
  defp redact_value(key, value) when is_binary(value) do
    if Tet.Redactor.sensitive_key?(key) or looks_like_secret?(value) do
      redact_sensitive(value)
    else
      value
    end
  end

  defp redact_value(_key, value) when is_map(value) do
    Map.new(value, fn {k, v} -> {k, redact_value(k, v)} end)
  end

  defp redact_value(_key, value) when is_list(value) do
    Enum.map(value, fn v -> redact_value("_item", v) end)
  end

  defp redact_value(_key, value), do: value

  defp looks_like_secret?(value) when is_binary(value) do
    String.match?(value, ~r/^(sk-|pk-|Bearer |token-|key-|ghp_|gho_|github_pat_|AKIA)/i) or
      (String.length(value) > 20 and String.match?(value, ~r/^[A-Za-z0-9_\-]{20,}$/))
  end

  defp looks_like_secret?(_), do: false

  defp redact_sensitive(value) when is_binary(value) do
    Tet.Secrets.partial_preview(value)
  end

  defp redact_sensitive(_value), do: "[REDACTED]"

  # ── File I/O for execute flow ───────────────────────────────────────────────

  @doc false
  @spec read_legacy_config(t()) :: {:ok, map()} | {:error, term()}
  defp read_legacy_config(%__MODULE__{source_path: nil}), do: {:error, :no_source_path}

  defp read_legacy_config(%__MODULE__{source_path: path}) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, parsed} when is_map(parsed) -> {:ok, parsed}
          {:ok, _not_a_map} -> {:error, {:invalid_config_format, path}}
          {:error, %Jason.DecodeError{} = e} -> {:error, {:json_parse_error, e}}
        end

      {:error, reason} ->
        {:error, {:source_read_failed, path, reason}}
    end
  end

  @doc false
  @spec write_target_config(t(), map()) :: :ok | {:error, term()}
  defp write_target_config(%__MODULE__{target_path: nil}, _mapped), do: {:error, :no_target_path}

  defp write_target_config(%__MODULE__{target_path: path}, mapped) do
    case Path.dirname(path) |> File.mkdir_p() do
      :ok ->
        content = Jason.encode!(mapped, pretty: true)

        case File.write(path, content) do
          :ok -> :ok
          {:error, reason} -> {:error, {:target_write_failed, path, reason}}
        end

      {:error, reason} ->
        {:error, {:target_dir_failed, path, reason}}
    end
  end
end
