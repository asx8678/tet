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

  1. Heuristic match on tool `:name` against known patterns.
  2. If the descriptor provides an explicit `:mcp_category` field, it can
     ONLY UPGRADE risk — never downgrade below the heuristic result.
     This prevents a malicious MCP server from self-reporting `:read` to
     bypass permission gates (the "self-report bypass" attack).
  3. Default to `:write` (fail-closed for unknown tools — safer than `:read`).

  ## Risk ordering

  `:read`(1) < `:write`(2) < `:network`(3) < `:shell`(4) < `:admin`(5)`

  Inspired by Codex `exec_policy.rs` which classifies commands into
  Allow/Prompt/Forbidden buckets using prefix rules and heuristics.
  """

  @categories [:read, :write, :shell, :network, :admin]
  @risk_indices %{read: 1, write: 2, shell: 4, network: 3, admin: 5}
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

  Uses heuristic (tool name analysis) primarily. Explicit `mcp_category` can
  only UPGRADE risk — never downgrade below heuristic. This prevents a
  malicious MCP server from self-reporting `:read` to bypass gates.

  ## Examples

      iex> Tet.Mcp.Classification.classify(%{name: "read_file"})
      :read

      iex> Tet.Mcp.Classification.classify(%{name: "delete_user"})
      :write

      iex> Tet.Mcp.Classification.classify(%{name: "run_bash", mcp_category: :shell})
      :shell

      iex> Tet.Mcp.Classification.classify(%{name: "run_bash", mcp_category: :read})
      :shell

      iex> Tet.Mcp.Classification.classify(%{name: "unknown_tool_xyz"})
      :write
  """
  @spec classify(descriptor()) :: category()
  def classify(descriptor) do
    heuristic = classify_by_name(descriptor)
    explicit = classify_by_explicit(descriptor)

    cond do
      explicit == nil -> heuristic
      risk_index(explicit) > risk_index(heuristic) -> explicit
      true -> heuristic
    end
  end

  @doc "Classifies by heuristic name analysis."
  @spec classify_by_name(descriptor()) :: category()
  def classify_by_name(%{name: name}) when is_binary(name), do: heuristic_from_name(name)
  def classify_by_name(%{"name" => name}) when is_binary(name), do: heuristic_from_name(name)
  def classify_by_name(_), do: :write

  @doc "Classifies by explicit mcp_category field (may be nil)."
  @spec classify_by_explicit(descriptor()) :: category() | nil
  def classify_by_explicit(%{mcp_category: cat}) when cat in @categories, do: cat

  def classify_by_explicit(%{"mcp_category" => cat}) when is_binary(cat),
    do: parse_category_string(cat)

  def classify_by_explicit(_), do: nil

  @doc "Returns the risk index for a category (higher = more dangerous)."
  @spec risk_index(category()) :: pos_integer()
  def risk_index(category) when category in @categories, do: Map.fetch!(@risk_indices, category)

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

  defp heuristic_from_name(name) do
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

  defp parse_category_string(cat) when is_binary(cat) do
    # Only convert known atoms — safe against atom table pollution
    try do
      atom = String.to_existing_atom(cat)
      if atom in @categories, do: atom, else: nil
    rescue
      ArgumentError -> nil
    end
  end

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
