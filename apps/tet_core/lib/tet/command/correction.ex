defmodule Tet.Command.Correction do
  @moduledoc """
  Correction suggestion generator for shell commands — BD-0048.

  Given a command string and optional context, generates safe alternatives
  or modifications. Never auto-runs dangerous commands — always returns a
  suggestion with appropriate risk assessment.

  ## Correction types

    - `:safe` — command is safe, returned as-is
    - `:modified` — command has been modified to be safer
    - `:blocked` — command is too dangerous, no safe alternative possible

  ## Integration

  Consumers check `requires_gate` on the suggestion before execution.
  All dangerous commands (high/critical) have `requires_gate: true`.
  """

  alias Tet.Command.{Risk, Suggestion}

  @doc """
  Given a command string and optional context, returns a list of suggestions.

  For dangerous commands: suggests safe alternatives with explanations.
  For medium commands: suggests with modifications where possible.
  For safe commands: returns as-is with no modification.

  ## Examples

      iex> suggestions = Tet.Command.Correction.suggest("rm -rf /", %{})
      iex> Enum.all?(suggestions, & &1.requires_gate)
      true
      iex> hd(suggestions).correction_type
      :blocked

      iex> [s] = Tet.Command.Correction.suggest("ls -la", %{})
      iex> s.correction_type
      :safe
      iex> s.requires_gate
      false
  """
  @spec suggest(String.t(), map()) :: [Suggestion.t()]
  def suggest(command, _context \\ %{}) when is_binary(command) do
    risk_level = Risk.classify(command)

    case risk_level do
      :critical -> suggest_critical(command)
      :high -> suggest_high(command)
      :medium -> suggest_medium(command)
      :low -> suggest_low(command)
      :none -> suggest_none(command)
    end
  end

  @doc """
  Validates that a suggestion isn't dangerous itself.

  Ensures that the suggested command, if present, doesn't classify
  at a higher risk level than the original command.
  """
  @spec validate_suggestion(Suggestion.t()) :: {:ok, Suggestion.t()} | {:error, String.t()}
  def validate_suggestion(%Suggestion{} = suggestion) do
    case suggestion.suggested_command do
      nil ->
        {:ok, suggestion}

      suggested when is_binary(suggested) ->
        original_risk = Risk.classify(suggestion.original_command)
        suggested_risk = Risk.classify(suggested)

        if Risk.requires_gate?(suggested_risk) and not Risk.requires_gate?(original_risk) do
          {:error, "suggested command is more dangerous than original"}
        else
          {:ok, suggestion}
        end
    end
  end

  # -- Critical suggestions --

  defp suggest_critical(command) do
    specific = extract_path(command)
    suggestions = build_critical_suggestions(command, specific)

    suggestions
  end

  defp build_critical_suggestions(command, specific) do
    cond do
      # rm -rf /
      String.match?(command, ~r/\brm\s+-rf\s+\/\s*$/) ->
        [
          build_suggestion(command, nil, :critical, :blocked,
            reason:
              "Deleting the root filesystem is never safe. No alternative can be suggested.",
            requires_gate: true
          )
        ]

      # rm -rf with specific path
      String.match?(command, ~r/\brm\s+-rf\b/) and not is_nil(specific) and specific != "/" ->
        safe_path = specific |> String.trim_trailing("/")
        trash_path = "~/.Trash/#{safe_path |> Path.basename()}"

        [
          build_suggestion(command, "mv #{safe_path} #{trash_path}", :critical, :modified,
            reason:
              "Use move to trash instead of permanent deletion. Original command is destructive.",
            requires_gate: true
          ),
          build_suggestion(
            command,
            "rm -rf #{safe_path} --interactive=once",
            :critical,
            :modified,
            reason: "Add --interactive flag for safety confirmation.",
            requires_gate: true
          )
        ]

      # DROP TABLE/DATABASE
      String.match?(command, ~r/\bDROP\s+(TABLE|DATABASE)\b/i) ->
        table = extract_db_object(command)

        [
          build_suggestion(command, nil, :critical, :blocked,
            reason:
              "DROP operations cannot be undone. Verify you have a backup and use a transaction. Original: #{command}",
            requires_gate: true
          ),
          build_suggestion(command, maybe_preview(command, table), :critical, :modified,
            reason: "Use a SELECT or transaction preview to confirm the impact first.",
            requires_gate: true
          )
        ]

      # Format/mkfs/dd
      String.match?(command, ~r/\b(dd|format|mkfs|mkswap)\b/) ->
        [
          build_suggestion(command, nil, :critical, :blocked,
            reason:
              "Low-level disk operations can permanently destroy data. Use with extreme caution.",
            requires_gate: true
          )
        ]

      # Mass delete
      true ->
        [
          build_suggestion(command, nil, :critical, :blocked,
            reason: "Mass delete detected. Use targeted deletions with explicit paths instead.",
            requires_gate: true
          )
        ]
    end
  end

  # -- High suggestions --

  defp suggest_high(command) do
    cond do
      # rm file
      String.match?(command, ~r/\brm\s+(?!-rf\b)/) ->
        specific = extract_path(command)

        if specific do
          trash_path = "~/.Trash/#{specific |> Path.basename()}"

          [
            build_suggestion(command, "mv #{specific} #{trash_path}", :high, :modified,
              reason: "Use move to trash instead of permanent deletion.",
              requires_gate: true
            ),
            build_suggestion(command, "rm -i #{specific}", :high, :modified,
              reason: "Add -i flag for interactive confirmation before deletion.",
              requires_gate: true
            )
          ]
        else
          [
            build_suggestion(command, "rm -i <file>", :high, :modified,
              reason: "Add -i flag for interactive confirmation before deletion.",
              requires_gate: true
            )
          ]
        end

      # chmod 777
      String.match?(command, ~r/\bchmod\s+777\b/) ->
        specific = extract_path(command)

        [
          build_suggestion(command, "chmod 755 #{specific || "<path>"}", :high, :modified,
            reason: "755 is safer than 777. Avoid world-writable permissions.",
            requires_gate: true
          ),
          build_suggestion(command, "chmod 700 #{specific || "<path>"}", :high, :modified,
            reason: "700 restricts access to owner only — most secure for sensitive files.",
            requires_gate: true
          )
        ]

      # UPDATE/DELETE without WHERE
      String.match?(command, ~r/\bDELETE\s+FROM\s+\w+(?:\s+(?!.*\bWHERE\b)|$)/i) ->
        [
          build_suggestion(
            command,
            "#{String.trim_trailing(command)} WHERE <condition>",
            :high,
            :modified,
            reason:
              "Add a WHERE clause to scope the deletion. Unfiltered DELETE removes all rows.",
            requires_gate: true
          )
        ]

      String.match?(command, ~r/\bUPDATE\s+\w+\s+SET\s+(?!.*\bWHERE\b)/i) ->
        [
          build_suggestion(
            command,
            "#{String.trim_trailing(command)} WHERE <condition>",
            :high,
            :modified,
            reason:
              "Add a WHERE clause to scope the update. Unfiltered UPDATE modifies all rows.",
            requires_gate: true
          )
        ]

      true ->
        [
          build_suggestion(command, nil, :high, :blocked,
            reason: "Operation is destructive and requires explicit approval.",
            requires_gate: true
          )
        ]
    end
  end

  # -- Medium suggestions --

  defp suggest_medium(command) do
    cond do
      # sed -i (in-place edit)
      String.match?(command, ~r/\bsed\s+-i\b/) ->
        [
          build_suggestion(command, command, :medium, :modified,
            reason: "In-place file edit. Consider backing up the file first or using sed -i.bak.",
            requires_gate: false
          )
        ]

      # Package install (apt, brew, npm, pip)
      String.match?(
        command,
        ~r/\b(apt-get|apt|brew|npm|yarn|pip|pip3|cargo)\s+(install|remove|uninstall)\b/
      ) ->
        [
          build_suggestion(command, command, :medium, :modified,
            reason: "Package installation modifies system state. Verify the package name.",
            requires_gate: false
          )
        ]

      # Service management
      String.match?(command, ~r/\b(service|systemctl)\s+\w+\s+(restart|stop|start)\b/) ->
        [
          build_suggestion(command, command, :medium, :modified,
            reason: "Service operation. Verify this won't affect other processes.",
            requires_gate: false
          )
        ]

      # sudo
      String.match?(command, ~r/\bsudo\s+/) ->
        [
          build_suggestion(
            command,
            String.replace(command, "sudo ", "", global: false),
            :medium,
            :modified,
            reason: "Running with elevated privileges. Consider if sudo is necessary.",
            requires_gate: false
          )
        ]

      true ->
        [
          build_suggestion(command, command, :medium, :safe,
            reason: "Medium-risk operation. Review before proceeding.",
            requires_gate: false
          )
        ]
    end
  end

  # -- Low suggestions --

  defp suggest_low(command) do
    [
      build_suggestion(command, command, :low, :safe,
        reason: "Low-risk operation — proceeding.",
        requires_gate: false
      )
    ]
  end

  # -- None suggestions --

  defp suggest_none(command) do
    [
      build_suggestion(command, command, :none, :safe,
        reason: "Safe read-only operation — proceeding.",
        requires_gate: false
      )
    ]
  end

  # -- Helpers --

  defp build_suggestion(original, suggested, risk_level, correction_type, opts) do
    reason = Keyword.fetch!(opts, :reason)
    requires_gate = Keyword.get(opts, :requires_gate, false)

    {:ok, suggestion} =
      Suggestion.new(%{
        original_command: original,
        suggested_command: suggested,
        risk_level: risk_level,
        reason: reason,
        requires_gate: requires_gate,
        correction_type: correction_type
      })

    suggestion
  end

  defp extract_path(command) do
    # Try to extract a file path from common patterns
    regexes = [
      ~r/\brm\s+(?:-rf\s+)?(.+?)(?:\s+\||\s*$)|\brm\s+(?!-rf\s+)(.+?)(?:\s+\||\s*$)/,
      ~r/\bchmod\s+\d+\s+(.+?)(?:\s+\||\s*$)/,
      ~r/\bchown\s+.+?\s+(.+?)(?:\s+\||\s*$)/
    ]

    Enum.find_value(regexes, fn regex ->
      case Regex.run(regex, command) do
        [_, a, b | _] -> a || b
        [_, path] -> path |> String.trim()
        _ -> nil
      end
    end)
  end

  defp extract_db_object(command) do
    case Regex.run(~r/\bDROP\s+(?:TABLE|DATABASE)\s+(\w+)/i, command) do
      [_, name] -> name
      nil -> nil
    end
  end

  defp maybe_preview(command, nil), do: command
  defp maybe_preview(_command, table), do: "SELECT COUNT(*) FROM #{table} WHERE ..."
end
