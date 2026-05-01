defmodule Tet.Command.Risk do
  @moduledoc """
  Risk classification for shell commands — BD-0048.

  Classifies command strings into five risk levels based on pattern
  matching against known dangerous patterns. Designed to prevent
  accidental destruction before commands reach the execution layer.

  ## Risk levels

    - `:none` — completely safe, read-only inspection
    - `:low` — minimal risk, safe mutations
    - `:medium` — moderate risk, file edits, package operations
    - `:high` — significant risk, destructive single-file operations
    - `:critical` — severe risk, system-destructive operations

  ## Integration

  Used by `Tet.Command.Correction` to generate safe alternatives and
  by `Tet.Runtime.Command.Gate` to enforce approval gates.
  """

  @doc """
  Classifies a command string into a risk level.

  Uses pattern matching against known dangerous patterns, ordered from
  most dangerous to least dangerous. Returns the highest matching risk level.

  ## Examples

      iex> Tet.Command.Risk.classify("ls -la")
      :none

      iex> Tet.Command.Risk.classify("rm -rf /")
      :critical

      iex> Tet.Command.Risk.classify("rm file.txt")
      :high

      iex> Tet.Command.Risk.classify("sed -i 's/foo/bar/' config.txt")
      :medium
  """
  @spec classify(String.t()) :: :none | :low | :medium | :high | :critical
  def classify(command) when is_binary(command) do
    cond do
      critical?(command) -> :critical
      high?(command) -> :high
      medium?(command) -> :medium
      low?(command) -> :low
      true -> :none
    end
  end

  @doc """
  Returns true if the risk level requires gate approval before execution.

  Commands at `:high` and `:critical` levels always require explicit approval.
  """
  @spec requires_gate?(:none | :low | :medium | :high | :critical) :: boolean()
  def requires_gate?(:high), do: true
  def requires_gate?(:critical), do: true
  def requires_gate?(_), do: false

  @doc """
  Returns a human-readable label for a risk level.
  """
  @spec risk_label(:none | :low | :medium | :high | :critical) :: String.t()
  def risk_label(:none), do: "No risk — read-only"
  def risk_label(:low), do: "Low risk — minimally invasive"
  def risk_label(:medium), do: "Medium risk — potentially destructive"
  def risk_label(:high), do: "High risk — destructive operation"
  def risk_label(:critical), do: "Critical risk — system-destructive"

  @doc """
  Returns all valid risk levels.
  """
  @spec levels() :: [:none | :low | :medium | :high | :critical]
  def levels, do: [:none, :low, :medium, :high, :critical]

  # -- Pattern matchers --

  # Critical patterns: system-destructive, irreversible operations
  defp critical?(cmd) do
    String.match?(cmd, ~r/\brm\s+-rf\b/) or
      String.match?(cmd, ~r/\brm\s+--recursive\b/) or
      String.match?(cmd, ~r/\brm\s+-r\s+\/\s*$/) or
      String.match?(cmd, ~r/\bdd\s+/) or
      String.match?(cmd, ~r/\bformat\s+/) or
      String.match?(cmd, ~r/\bmkfs(?:\..*)?\s+/) or
      String.match?(cmd, ~r/\bmkswap(?:\..*)?\s+/) or
      String.match?(cmd, ~r/\bDROP\s+(TABLE|DATABASE)\b/i) or
      String.match?(cmd, ~r/\bDROP\s+SCHEMA\b/i) or
      String.match?(cmd, ~r/\bDROP\s+COLLECTION\b/i) or
      String.match?(cmd, ~r/\bbq\s+rm\b/) or
      String.match?(cmd, ~r/\bgcloud\s+.*\bdelete\b/) or
      String.match?(cmd, ~r/\baws\s+s3\s+rb\b/) or
      mass_delete?(cmd)
  end

  # High patterns: destructive but scoped to specific files/records
  defp high?(cmd) do
    String.match?(cmd, ~r/\brm\s+(?!-rf\b)/) or
      String.match?(cmd, ~r/\brmdir\s+/) or
      String.match?(cmd, ~r/\bchmod\s+777\b/) or
      String.match?(cmd, ~r/\bchmod\s+[0-7]77\b/) or
      String.match?(cmd, ~r/\bchown\s+-R\b/) or
      String.match?(cmd, ~r/\bUPDATE\s+\w+\s+SET\s+(?!.*\bWHERE\b)/i) or
      String.match?(cmd, ~r/\bDELETE\s+FROM\s+\w+\s+WHERE\s+1\s*=\s*1\b/i) or
      String.match?(cmd, ~r/\bDELETE\s+FROM\s+\w+\s+WHERE\s+true\b/i) or
      String.match?(cmd, ~r/\bTRUNCATE\b/i) or
      String.match?(cmd, ~r/\bDELETE\s+FROM\s+\w+(?:\s+(?!.*\bWHERE\b)|$)/i) or
      String.match?(cmd, ~r/\bREINDEX\b/i) or
      String.match?(cmd, ~r/\bsudo\s+rm\b/) or
      String.match?(cmd, ~r/\bsudo\s+.*\b(DROP|DELETE|FORMAT)\b/i)
  end

  # Medium patterns: file edits, package operations, service management
  defp medium?(cmd) do
    String.match?(cmd, ~r/\bsed\s+-i\b/) or
      String.match?(cmd, ~r/\bcat\s+>/) or
      String.match?(cmd, ~r/\B>\s+[^\s]/) or
      String.match?(cmd, ~r/\B>>\s+[^\s]/) or
      String.match?(cmd, ~r/\bapt(\-get)?\s+(install|remove|purge|autoremove)\b/) or
      String.match?(cmd, ~r/\bbrew\s+(install|uninstall|update|upgrade)\b/) or
      String.match?(cmd, ~r/\bnpm\s+(install|uninstall|update|audit\s+fix)\b/) or
      String.match?(cmd, ~r/\byarn\s+(add|remove|upgrade)\b/) or
      String.match?(cmd, ~r/\bpip\s+(install|uninstall)\b/) or
      String.match?(cmd, ~r/\bpip3\s+(install|uninstall)\b/) or
      String.match?(cmd, ~r/\bcargo\s+(install|remove|update)\b/) or
      String.match?(cmd, ~r/\bmix\s+deps\.(get|update|clean)\b/) or
      String.match?(cmd, ~r/\bmix\s+test\s+--\w+/) or
      String.match?(cmd, ~r/\bcurl\s+-[a-zA-Z]*[oO]\b/) or
      String.match?(cmd, ~r/\bwget\s+-[a-zA-Z]*[oO]\b/) or
      String.match?(cmd, ~r/\bservice\s+\w+\s+(restart|stop|start|reload)\b/) or
      String.match?(cmd, ~r/\bsystemctl\s+(restart|stop|start|reload|enable|disable)\b/) or
      String.match?(cmd, ~r/\bgit\s+checkout\s+-[bB]\b/) or
      String.match?(cmd, ~r/\bgit\s+reset\b/) or
      String.match?(cmd, ~r/\bgit\s+clean\b/) or
      String.match?(cmd, ~r/\bgit\s+rebase\b/) or
      String.match?(cmd, ~r/\bsudo\s+/)
  end

  # Low patterns: safe operations with minimal side effects
  defp low?(cmd) do
    String.match?(cmd, ~r/\bmkdir\s+/) or
      String.match?(cmd, ~r/\btouch\s+/) or
      String.match?(cmd, ~r/\bcp\s+/) or
      String.match?(cmd, ~r/\bmv\s+/) or
      String.match?(cmd, ~r/\bln\s+-[a-z]*s\b/) or
      String.match?(cmd, ~r/\bchmod\s+(?!(777|[0-7]77)\b)/) or
      String.match?(cmd, ~r/\bgit\s+(add|restore|commit)\b/) or
      String.match?(cmd, ~r/\bgit\s+(init|clone)\b/) or
      String.match?(cmd, ~r/\bgit\s+push\b/) or
      String.match?(cmd, ~r/\bgit\s+pull\b/) or
      String.match?(cmd, ~r/\bgit\s+fetch\b/) or
      String.match?(cmd, ~r/\bgit\s+merge\b/) or
      String.match?(cmd, ~r/\bgit\s+branch\b/) or
      String.match?(cmd, ~r/\bgit\s+tag\b/) or
      String.match?(cmd, ~r/\bgit\s+remote\b/) or
      String.match?(cmd, ~r/\bmix\s+format\b/) or
      String.match?(cmd, ~r/\bmix\s+compile\b/) or
      String.match?(cmd, ~r/\bmix\s+test\b/) or
      String.match?(cmd, ~r/\bmix\s+run\b/) or
      String.match?(cmd, ~r/\bmix\s+phx\b/) or
      String.match?(cmd, ~r/\bSELECT\b/i) or
      String.match?(cmd, ~r/\bINSERT\s+INTO\b/i) or
      String.match?(cmd, ~r/\bUPDATE\s+\w+\s+SET\s+.*\bWHERE\b/i) or
      String.match?(cmd, ~r/\bDELETE\s+FROM\s+\w+\s+.*\bWHERE\b/i) or
      String.match?(cmd, ~r/\bCREATE\s+(TABLE|INDEX|VIEW|SCHEMA)\b/i) or
      String.match?(cmd, ~r/\bALTER\s+(TABLE|INDEX|VIEW|SCHEMA)\b/i)
  end

  # Mass delete patterns — deleting many things at once
  defp mass_delete?(cmd) do
    String.match?(cmd, ~r/\bfind\s+.*\s+-delete\b/) or
      String.match?(cmd, ~r/\bfind\s+.*\s+-exec\s+rm\b/) or
      String.match?(cmd, ~r/\bxargs\s+rm\b/) or
      String.match?(cmd, ~r/\brm\s+-rf\s+[^*]*\*\s*/) or
      String.match?(cmd, ~r/\brm\s+-rf\s+\.\//) or
      String.match?(cmd, ~r/\brm\s+-rf\s+\~\//)
  end
end
