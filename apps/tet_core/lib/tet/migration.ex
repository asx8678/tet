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
          items: [map()],
          warnings: [binary()],
          status: status()
        }

  defstruct [
    :source_path,
    :target_path,
    :backup_path,
    mode: :dry_run,
    items: [],
    warnings: [],
    status: :pending
  ]

  @valid_modes [:dry_run, :execute]
  # ── Construction ──────────────────────────────────────────────────────────

  @doc """
  Validates attrs and creates a new Migration struct.

  Accepts both atom and string keys. Defaults mode to `:dry_run` and status
  to `:pending`.
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
        items: get_attr(attrs, :items, []),
        warnings: get_attr(attrs, :warnings, []),
        status: get_attr(attrs, :status, :pending)
      }

      {:ok, migration}
    end
  end

  def new(_), do: {:error, :invalid_attrs}

  # ── Analysis ──────────────────────────────────────────────────────────────

  @doc """
  Analyzes a legacy config map and populates migration items.

  Each item is a map with `:key`, `:value`, `:section`, `:new_key`, and
  `:transformed` fields. Unsafe keys are added to warnings.
  """
  @spec analyze(t(), map()) :: t()
  def analyze(%__MODULE__{} = migration, legacy_config) when is_map(legacy_config) do
    {:ok, mapped, unsafe_found} = ConfigMapper.map_config(legacy_config)

    items = build_items(legacy_config, mapped)

    warnings =
      unsafe_found
      |> Enum.map(&"Unsafe key '#{&1}' requires manual review")
      |> Kernel.++(migration.warnings)

    %{migration | items: items, warnings: warnings, status: :analyzed}
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
    safety_warnings = SafetyCheck.warnings(migration)

    all_warnings = migration.warnings ++ safety_warnings

    %{migration | warnings: all_warnings, status: :dry_run_complete}
  end

  def dry_run(%__MODULE__{status: status}) do
    raise ArgumentError, "Cannot dry_run from status #{inspect(status)}. Must be :analyzed first."
  end

  # ── Report ───────────────────────────────────────────────────────────────

  @doc """
  Generates a human-readable report of the migration dry-run.

  Shows items that would be migrated, warnings, and overall safety status.
  """
  @spec report(t()) :: binary()
  def report(%__MODULE__{} = migration) do
    lines = [
      header_line(migration),
      item_lines(migration),
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

  defp validate_source(attrs) do
    if Map.has_key?(attrs, :source_path) or Map.has_key?(attrs, "source_path") do
      :ok
    else
      {:error, :source_path_required}
    end
  end

  defp validate_mode(%{mode: mode}) when mode in @valid_modes, do: :ok
  defp validate_mode(%{mode: mode}), do: {:error, {:invalid_mode, mode}}
  defp validate_mode(_attrs), do: :ok

  defp get_attr(attrs, key, default \\ nil) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key), default)
  end

  defp build_items(legacy_config, mapped) do
    compatible = ConfigMapper.compatible_keys()

    compatible
    |> Enum.filter(&Map.has_key?(legacy_config, &1))
    |> Enum.map(fn key ->
      value = legacy_config[key]
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
        "  #{item.key} → #{item.section}.#{item.new_key} = #{inspect(item.transformed)}"
      end)

    ["── Items ──"] ++ item_lines ++ [""]
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
end
