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
  """
  @spec dry_run(t()) :: t()
  def dry_run(%__MODULE__{status: :analyzed} = migration) do
    # Only add warnings that aren't already present (avoids duplication)
    safety_warnings = SafetyCheck.warnings(migration)

    existing_set = MapSet.new(migration.warnings)
    new_warnings = Enum.reject(safety_warnings, &MapSet.member?(existing_set, &1))

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
  """
  @spec execute(t()) :: {:ok, t()} | {:error, term()}
  def execute(%__MODULE__{mode: :dry_run} = migration) do
    {:error, {:cannot_execute_in_dry_run, migration}}
  end

  def execute(%__MODULE__{mode: :execute} = migration) do
    with true <- SafetyCheck.safe_to_execute?(migration),
         {:ok, migration} <- create_backup(migration) do
      # Write mapped config to target_path
      {:ok, mapped, _unsafe, _unknown} = ConfigMapper.map_config(read_legacy_config(migration))

      case write_target_config(migration, mapped) do
        :ok -> {:ok, %{migration | status: :executed}}
        {:error, reason} -> {:error, reason}
      end
    else
      false -> {:error, :not_safe_to_execute}
      {:error, reason} -> {:error, reason}
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
        "  ⚠  #{w}"
      end)

    ["── Warnings ──"] ++ warning_lines ++ [""]
  end

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
  defp redact_value(key, value) do
    if Tet.Redactor.sensitive_key?(key) do
      redact_sensitive(value)
    else
      value
    end
  end

  defp redact_sensitive(value) when is_binary(value) do
    Tet.Secrets.partial_preview(value)
  end

  defp redact_sensitive(_value), do: "[REDACTED]"

  # Stubs for execute flow — actual file I/O
  defp read_legacy_config(migration) do
    case File.read(migration.source_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, parsed} -> parsed
          {:error, _} -> %{}
        end

      {:error, _} ->
        %{}
    end
  end

  defp write_target_config(migration, mapped) do
    migration.target_path
    |> Path.dirname()
    |> File.mkdir_p()

    content = Jason.encode!(mapped, pretty: true)
    File.write(migration.target_path, content)
  end
end
