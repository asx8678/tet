defmodule Tet.Mcp.Classification do
  @moduledoc """
  MCP tool classification by risk category.

  Every MCP tool descriptor is classified into one of five risk categories.
  Classification is a pure function — no side effects, no IO, no processes.
  Runtime layers consume the classification to enforce permission gates.

  ## Risk categories (ascending severity)

    - `:read`    — safe, inspect-only (file reads, list, search)
    - `:write`   — needs approval (file writes, creates, deletes, patches)
    - `:shell`   — dangerous, needs explicit gate (bash, exec, run commands)
    - `:network` — external network access (http, fetch, curl)
    - `:admin`   — system administration (config changes, sudo, user management)

  ## Classification strategy

  1. If the descriptor provides an explicit `:mcp_category` field, trust it
     (server-declared intent).
  2. Otherwise, heuristic match on tool `:name` against known patterns.
  3. Default to `:write` (fail-closed for unknown tools — safer than `:read`).

  Inspired by Codex `exec_policy.rs` which classifies commands into
  Allow/Prompt/Forbidden buckets using prefix rules and heuristics.
  """

  @categories [:read, :write, :shell, :network, :admin]
  @risk_levels %{
    read: :low,
    write: :medium,
    shell: :high,
    network: :high,
    admin: :critical
  }

  # Pattern → category maps. Order matters: first match wins.
  @read_patterns ~w(read get list find search view show inspect head status query count diff)
  @write_patterns ~w(write create update delete remove patch save insert add set put modify rename move copy)
  @shell_patterns ~w(shell exec run bash zsh terminal spawn evaluate compile build)
  @network_patterns ~w(fetch http request curl wget ping connect upload download api call_proxy proxy)
  @admin_patterns ~w(admin config manage sudo install uninstall deploy grant revoke permissions policy)

  @type category :: :read | :write | :shell | :network | :admin
  @type risk_level :: :low | :medium | :high | :critical
  @type descriptor :: %{required(:name) => String.t(), optional(:mcp_category) => category()}

  @doc "Returns all known risk categories in ascending severity order."
  @spec categories() :: [category()]
  def categories, do: @categories

  @doc "Returns all known risk levels in ascending severity order."
  @spec risk_levels() :: [risk_level()]
  def risk_levels, do: [:low, :medium, :high, :critical]

  @doc """
  Classifies an MCP tool descriptor into a risk category.

  ## Examples

      iex> Tet.Mcp.Classification.classify(%{name: "read_file"})
      :read

      iex> Tet.Mcp.Classification.classify(%{name: "delete_user"})
      :write

      iex> Tet.Mcp.Classification.classify(%{name: "run_bash", mcp_category: :shell})
      :shell

      iex> Tet.Mcp.Classification.classify(%{name: "unknown_tool_xyz"})
      :write
  """
  @spec classify(descriptor()) :: category()
  def classify(%{mcp_category: category}) when category in @categories, do: category

  def classify(%{name: name}) when is_binary(name) do
    normalized = String.downcase(name)

    cond do
      matches_any?(normalized, @admin_patterns) -> :admin
      matches_any?(normalized, @shell_patterns) -> :shell
      matches_any?(normalized, @network_patterns) -> :network
      matches_any?(normalized, @write_patterns) -> :write
      matches_any?(normalized, @read_patterns) -> :read
      true -> :write
    end
  end

  def classify(_), do: :write

  @doc """
  Returns the risk level for a classification category.

  ## Examples

      iex> Tet.Mcp.Classification.risk_level(:read)
      :low

      iex> Tet.Mcp.Classification.risk_level(:admin)
      :critical
  """
  @spec risk_level(category()) :: risk_level()
  def risk_level(category) when category in @categories do
    Map.fetch!(@risk_levels, category)
  end

  @doc "Returns true when the category is considered safe (no approval needed)."
  @spec safe?(category()) :: boolean()
  def safe?(:read), do: true
  def safe?(_category), do: false

  @doc "Returns true when the category requires explicit approval before execution."
  @spec requires_approval?(category()) :: boolean()
  def requires_approval?(:read), do: false
  def requires_approval?(:write), do: true
  def requires_approval?(:shell), do: true
  def requires_approval?(:network), do: true
  def requires_approval?(:admin), do: true

  # -- Private --

  # Tokenize the tool name into word segments (split on _ and -),
  # then check if any token starts with a known pattern.
  # This avoids false positives like "sh" matching "show".
  defp matches_any?(normalized, patterns) do
    tokens = tokenize(normalized)

    Enum.any?(patterns, fn pattern ->
      Enum.any?(tokens, &String.starts_with?(&1, pattern))
    end)
  end

  defp tokenize(name) do
    name
    |> String.split(~r/[_\-]+/)
    |> Enum.filter(&(byte_size(&1) > 0))
  end
end
