defmodule Tet.Migration.SafetyCheck do
  @moduledoc """
  Safety validations for the migration dry-run workflow — BD-0072.

  Migration is a destructive-ish operation. Unsafe serialized data, missing
  backups, and other foot-guns are caught here BEFORE any files are touched.
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
    # Base64-encoded binaries that look like serialized data
    ~r/^[A-Za-z0-9+\/]{40,}={0,2}$/
  ]

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
  Returns all safety warnings for a migration plan.

  Warnings include:
  - Unsafe keys found in the legacy config
  - Potentially unsafe serialized data detected
  - Missing backup (if mode is :execute)
  """
  @spec warnings(Migration.t()) :: [binary()]
  def warnings(%Migration{warnings: plan_warnings, mode: mode, backup_path: bp} = plan) do
    base_warnings = Enum.map(plan_warnings, &"#{&1}")

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

    base_warnings ++ serialized_warnings ++ backup_warnings
  end

  @doc """
  Returns `true` only if all safety checks pass for the migration.

  Requirements:
  - No warnings that indicate unsafe data or missing backup
  - If mode is :execute, a backup must exist
  """
  @spec safe_to_execute?(Migration.t()) :: boolean()
  def safe_to_execute?(%Migration{mode: :dry_run}), do: true

  def safe_to_execute?(%Migration{mode: :execute} = plan) do
    check_backup_exists(plan) == :ok and
      check_serialized_data(plan) == [] and
      warnings(plan) == []
  end

  def safe_to_execute?(%Migration{}), do: false
end
