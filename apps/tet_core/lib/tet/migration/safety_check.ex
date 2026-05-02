defmodule Tet.Migration.SafetyCheck do
  @moduledoc """
  Safety validations for the migration dry-run workflow — BD-0072.

  Migration is a destructive-ish operation. Unsafe serialized data, missing
  backups, and other foot-guns are caught here BEFORE any files are touched.

  Safety scanning happens in two passes:
  1. **Raw legacy scan** — inspects ALL key/value pairs before any filtering
  2. **Mapped items scan** — inspects only the mapped migration items

  This two-pass approach ensures unknown keys with dangerous serialized content
  (pickle bytes, eval strings) are caught even though they'd be silently dropped
  during mapping.
  """

  alias Tet.Migration

  @serialized_patterns [
    # Elixir/Erlang serialized terms
    ~r/%\s*\{\s*__struct__/,
    ~r/:erlang\.binary_to_term/,
    ~r/:erlang\.term_to_binary/,
    # Potential code injection markers
    ~r/import\s+/,
    ~r/require\s+/,
    ~r/Code\.eval_string/,
    ~r/Code\.eval_quoted/,
    # Python pickle magic bytes (as hex-escaped string representation)
    ~r/\\x80\\x[0-9a-f]{2}/,
    # Base64-encoded binaries that look like serialized data
    ~r/^[A-Za-z0-9+\/]{40,}={0,2}$/
  ]

  # 0x80 — Python pickle protocol start byte
  @pickle_magic_bytes <<128>>

  # ── Raw legacy scanning ───────────────────────────────────────────────────

  @doc """
  Scans ALL raw legacy config key/value pairs BEFORE any filtering.

  This catches unknown keys containing dangerous serialized data that would
  be silently dropped during ConfigMapper's key filtering. Returns a tuple
  of `{raw_warnings, skipped_items}` where:
  - `raw_warnings` — warning strings for suspicious unknown keys
  - `skipped_items` — maps with `:key`, `:value`, `:reason` for manual review
  """
  @spec check_raw_legacy_data(map()) :: {[binary()], [map()]}
  def check_raw_legacy_data(legacy_config) when is_map(legacy_config) do
    compatible_set = MapSet.new(Tet.Migration.ConfigMapper.compatible_keys())
    unsafe_set = MapSet.new(Tet.Migration.ConfigMapper.unsafe_keys())

    legacy_config
    |> Enum.reduce({[], []}, fn {key, value}, {warn_acc, skip_acc} ->
      key_str = stringify(key)

      cond do
        # Known compatible keys — will be handled by normal scanning
        MapSet.member?(compatible_set, key_str) ->
          {warn_acc, skip_acc}

        # Known unsafe keys — already have dedicated warning path
        MapSet.member?(unsafe_set, key_str) ->
          {warn_acc, skip_acc}

        # Unknown keys — scan for danger
        true ->
          check_unknown_key(key_str, value, warn_acc, skip_acc)
      end
    end)
    |> then(fn {w, s} -> {Enum.reverse(w), Enum.reverse(s)} end)
  end

  defp check_unknown_key(key_str, value, warn_acc, skip_acc) do
    value_str = inspect(value)

    cond do
      contains_pickle_bytes?(value) ->
        warning = "Unknown key '#{key_str}' contains pickle magic bytes — manual review required"
        skip_item = %{key: key_str, value: value, reason: :pickle_magic_bytes}
        {[warning | warn_acc], [skip_item | skip_acc]}

      matches_serialized_pattern?(value_str) ->
        warning =
          "Unknown key '#{key_str}' contains serialized data patterns — manual review required"

        skip_item = %{key: key_str, value: value, reason: :serialized_data_pattern}
        {[warning | warn_acc], [skip_item | skip_acc]}

      true ->
        # Unknown key but no danger detected — still note it for review
        skip_item = %{key: key_str, value: value, reason: :unknown_key}
        {warn_acc, [skip_item | skip_acc]}
    end
  end

  defp contains_pickle_bytes?(value) when is_binary(value) do
    # Check for Python pickle protocol header byte (0x80)
    String.starts_with?(value, @pickle_magic_bytes) or
      String.contains?(value, <<128>>)
  end

  defp contains_pickle_bytes?(value) when is_list(value) do
    Enum.any?(value, &contains_pickle_bytes?/1)
  end

  defp contains_pickle_bytes?(_), do: false

  defp matches_serialized_pattern?(value_str) do
    Enum.any?(@serialized_patterns, &Regex.match?(&1, value_str))
  end

  # ── Mapped items scanning ─────────────────────────────────────────────────

  @doc """
  Scans migration items for potentially unsafe serialized data.

  Returns a list of item keys that contain content matching known unsafe
  serialization patterns. Never blindly execute or deserialize these.
  """
  @spec check_serialized_data(Migration.t()) :: [binary()]
  def check_serialized_data(%Migration{items: items}) do
    items
    |> Enum.filter(fn item ->
      value = item[:value] || item["value"] || ""
      serialized_value = inspect(value)
      Enum.any?(@serialized_patterns, &Regex.match?(&1, serialized_value))
    end)
    |> Enum.map(fn item -> item[:key] || item["key"] || "unknown" end)
  end

  # ── Backup ────────────────────────────────────────────────────────────────

  @doc """
  Verifies that a backup file exists for the migration.

  Returns `:ok` if the backup file exists, or `{:error, reason}` if not.
  """
  @spec check_backup_exists(Migration.t()) :: :ok | {:error, term()}
  def check_backup_exists(%Migration{backup_path: nil}), do: {:error, :no_backup_path}

  def check_backup_exists(%Migration{backup_path: backup_path}) do
    if File.exists?(backup_path) do
      :ok
    else
      {:error, {:backup_not_found, backup_path}}
    end
  end

  @doc """
  Creates a backup of the current target config file.

  Creates the backup directory if needed, copies the target file to the
  backup path. Will not overwrite an existing backup unless `force: true`
  is set on the migration struct.

  Returns `{:ok, migration}` on success or `{:error, reason}` on failure.
  """
  @spec create_backup(Migration.t()) :: {:ok, Migration.t()} | {:error, term()}
  def create_backup(%Migration{target_path: nil}), do: {:error, :no_target_path}
  def create_backup(%Migration{backup_path: nil}), do: {:error, :no_backup_path}

  def create_backup(
        %Migration{target_path: target, backup_path: backup, force: force} = migration
      ) do
    cond do
      not File.exists?(target) ->
        # No target file yet — fresh install, nothing to back up
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

  # ── Warnings ─────────────────────────────────────────────────────────────

  @doc """
  Returns all safety warnings for a migration plan.

  Warnings include:
  - Potentially unsafe serialized data in mapped items
  - Raw legacy warnings from unknown keys with dangerous content
  - Missing backup (if mode is :execute)
  """
  @spec warnings(Migration.t()) :: [binary()]
  def warnings(%Migration{mode: mode, backup_path: bp, raw_warnings: rw} = plan) do
    serialized_warnings =
      case check_serialized_data(plan) do
        [] ->
          []

        unsafe_items ->
          [
            "Potentially unsafe serialized data detected in keys: " <>
              Enum.join(unsafe_items, ", ") <>
              ". These items require manual review before execution."
          ]
      end

    backup_warnings =
      if mode == :execute and (is_nil(bp) or check_backup_exists(plan) != :ok) do
        ["Backup must be created before executing migration."]
      else
        []
      end

    # Include raw_warnings from unknown key scanning
    raw_warning_list = Enum.map(rw, &"#{&1}")

    serialized_warnings ++ raw_warning_list ++ backup_warnings
  end

  # ── Safety gates ─────────────────────────────────────────────────────────

  @doc """
  Returns `true` only if the migration plan is safe for a dry-run.

  A dry-run with unsafe serialized data or missing backup should NOT
  be considered safe — it indicates the plan itself is flawed.
  """
  @spec safe_to_dry_run?(Migration.t()) :: boolean()
  def safe_to_dry_run?(%Migration{mode: :dry_run} = plan) do
    check_serialized_data(plan) == [] and plan.raw_warnings == []
  end

  def safe_to_dry_run?(_), do: false

  @doc """
  Returns `true` only if all safety checks pass for execution.

  Requirements:
  - No unsafe serialized data in mapped items
  - No raw legacy warnings (unknown keys with dangerous content)
  - A backup must exist or be creatable
  """
  @spec safe_to_execute?(Migration.t()) :: boolean()
  def safe_to_execute?(%Migration{mode: :execute} = plan) do
    check_backup_exists(plan) == :ok and
      check_serialized_data(plan) == [] and
      plan.raw_warnings == [] and
      warnings(plan) == []
  end

  def safe_to_execute?(%Migration{}), do: false

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: "#{value}"
end
