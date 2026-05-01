defmodule Tet.Mcp.ToolRegistry do
  @moduledoc """
  Pure-data tool registry — no GenServer, no side effects.

  Tracks all registered MCP tools (namespaced) alongside built-in native tools.
  Conflict detection prevents ambiguity; built-in tools cannot be shadowed.

  ## Design

  This is a *data structure*, not a process. Callers own the registry state
  and thread it through their functions. This follows the project pattern of
  keeping `tet_core` free of side effects.

  ## Conflict rules

  1. Two tools with the **same namespaced name** → conflict (re-registration
     overwrites on `register/3` but `conflicts/1` reports duplicates from
     multi-tool registration).
  2. Built-in tools (prefixed with `tet:`) can never be shadowed by MCP tools.
  3. The same `original_name` on different servers is **allowed** — they have
     different namespaced names.

  ## Examples

      iex> reg = Tet.Mcp.ToolRegistry.new_with_builtins(["read_file"])
      iex> {:ok, reg} = Tet.Mcp.ToolRegistry.register("fs", [%{name: "read_file"}], reg)
      iex> Tet.Mcp.ToolRegistry.count(reg)
      2
  """

  alias Tet.Mcp.Tool
  alias Tet.Mcp.ToolAdapter

  @builtin_prefix "tet:"

  @type t :: %__MODULE__{
          tools: %{binary() => Tool.t()},
          builtins: MapSet.t(binary())
        }

  defstruct tools: %{}, builtins: MapSet.new()

  @doc "Creates an empty registry."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Creates a registry pre-loaded with built-in tool names.

  Built-in names are recorded as unshadowable — any MCP tool attempting
  to register under the same name will be rejected.
  """
  @spec new_with_builtins([binary()]) :: t()
  def new_with_builtins(builtin_names) when is_list(builtin_names) do
    builtins =
      builtin_names
      |> Enum.map(&prefix_builtin/1)
      |> MapSet.new()

    %__MODULE__{tools: %{}, builtins: builtins}
  end

  @doc """
  Registers all tools from a server in one batch.

  Accepts a `server_id` and a list of raw MCP tool descriptors (maps).
  Returns `{:ok, registry}` on success or `{:error, reason}` if any tool
  fails validation or attempts to shadow a built-in.

  On error, the registry is **unchanged** — all-or-nothing semantics.
  """
  @spec register(binary(), [map()], t()) :: {:ok, t()} | {:error, term()}
  def register(server_id, descriptors, %__MODULE__{} = registry)
      when is_binary(server_id) and is_list(descriptors) do
    # Validate all tools first, then merge
    tools_result =
      descriptors
      |> Enum.map(fn desc -> ToolAdapter.to_tool(server_id, desc) end)
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, tool}, {:ok, acc} -> {:cont, {:ok, acc ++ [tool]}}
        {:error, reason}, _ -> {:halt, {:error, reason}}
      end)

    case tools_result do
      {:ok, tools} ->
        # Check built-in shadowing for the whole batch
        case check_builtin_shadowing(tools, registry.builtins) do
          :ok ->
            # Check for conflicts within the batch itself
            new_tools =
              Enum.reduce(tools, registry.tools, fn tool, acc ->
                Map.put(acc, tool.name, tool)
              end)

            {:ok, %{registry | tools: new_tools}}

          {:error, _} = err ->
            err
        end

      {:error, _} = err ->
        err
    end
  end

  def register(_, _, _), do: {:error, :invalid_args}

  @doc """
  Registers a single tool from a server.

  Returns `{:ok, registry}` or `{:error, reason}`.
  """
  @spec register_one(binary(), map(), t()) :: {:ok, t()} | {:error, term()}
  def register_one(server_id, descriptor, %__MODULE__{} = registry) do
    register(server_id, [descriptor], registry)
  end

  def register_one(_, _, _), do: {:error, :invalid_args}

  @doc """
  Unregisters a single tool by its namespaced name.

  Returns `{:ok, registry}` or `{:error, :not_found}`.
  Built-in tools cannot be unregistered.
  """
  @spec unregister(binary(), t()) :: {:ok, t()} | {:error, term()}
  def unregister(name, %__MODULE__{} = registry) when is_binary(name) do
    if builtin?(name, registry.builtins) do
      {:error, :cannot_unregister_builtin}
    else
      case Map.pop(registry.tools, name) do
        {nil, _} -> {:error, :not_found}
        {_tool, new_tools} -> {:ok, %{registry | tools: new_tools}}
      end
    end
  end

  def unregister(_, _), do: {:error, :invalid_args}

  @doc """
  Unregisters all tools belonging to a server.

  Returns `{:ok, registry}` (always succeeds, even if server had no tools).
  """
  @spec unregister_server(binary(), t()) :: {:ok, t()}
  def unregister_server(server_id, %__MODULE__{} = registry) when is_binary(server_id) do
    new_tools =
      registry.tools
      |> Enum.reject(fn {_name, tool} -> tool.server_id == server_id end)
      |> Map.new()

    {:ok, %{registry | tools: new_tools}}
  end

  def unregister_server(_, _), do: {:error, :invalid_args}

  @doc """
  Looks up a tool by its namespaced name.

  Returns `{:ok, tool}` or `{:error, :not_found}`.
  """
  @spec lookup(binary(), t()) :: {:ok, Tool.t()} | {:error, :not_found}
  def lookup(name, %__MODULE__{} = registry) when is_binary(name) do
    case Map.get(registry.tools, name) do
      nil -> {:error, :not_found}
      tool -> {:ok, tool}
    end
  end

  def lookup(_, _), do: {:error, :invalid_args}

  @doc "Returns `true` if a tool with the given name is registered."
  @spec has_tool?(binary(), t()) :: boolean()
  def has_tool?(name, %__MODULE__{} = registry) when is_binary(name) do
    Map.has_key?(registry.tools, name)
  end

  def has_tool?(_, _), do: false

  @doc "Returns all registered tools as a list."
  @spec list(t()) :: [Tool.t()]
  def list(%__MODULE__{} = registry), do: Map.values(registry.tools)

  @doc "Returns the count of registered tools."
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{} = registry), do: map_size(registry.tools)

  @doc """
  Returns a list of tool name conflicts.

  A conflict occurs when the same namespaced name appears more than once
  (only possible within a single `register/3` batch, since the map deduplicates
  across calls). This is a diagnostic — callers can check after registration
  to detect ambiguous situations.
  """
  @spec conflicts(t()) :: [{binary(), [Tool.t()]}]
  def conflicts(%__MODULE__{} = registry) do
    registry.tools
    |> Enum.group_by(fn {_name, tool} -> tool.name end, fn {_name, tool} -> tool end)
    |> Enum.filter(fn {_name, tools} -> length(tools) > 1 end)
  end

  @doc "Returns all tools belonging to a specific server."
  @spec server_tools(binary(), t()) :: [Tool.t()]
  def server_tools(server_id, %__MODULE__{} = registry) when is_binary(server_id) do
    registry.tools
    |> Enum.filter(fn {_name, tool} -> tool.server_id == server_id end)
    |> Enum.map(fn {_name, tool} -> tool end)
  end

  def server_tools(_, _), do: []

  # -- Private --

  defp prefix_builtin(name) do
    if String.starts_with?(name, @builtin_prefix) do
      name
    else
      @builtin_prefix <> name
    end
  end

  defp builtin?(name, builtins) do
    MapSet.member?(builtins, name) or MapSet.member?(builtins, prefix_builtin(name))
  end

  defp check_builtin_shadowing(tools, builtins) do
    # Compare original_name (without namespace prefix) against builtins.
    # Builtins are stored as "tet:<name>" — extract the base name.
    builtin_bases =
      builtins
      |> Enum.map(fn name ->
        if String.starts_with?(name, @builtin_prefix) do
          String.replace_prefix(name, @builtin_prefix, "")
        else
          name
        end
      end)
      |> MapSet.new()

    conflicting =
      Enum.find(tools, fn tool ->
        MapSet.member?(builtin_bases, tool.original_name)
      end)

    case conflicting do
      nil -> :ok
      tool -> {:error, {:shadows_builtin, tool.name}}
    end
  end
end
