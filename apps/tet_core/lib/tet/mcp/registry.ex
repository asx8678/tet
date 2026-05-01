defmodule Tet.Mcp.Registry do
  @moduledoc """
  GenServer managing MCP server configurations and health tracking.

  The Registry is the book of record for all known MCP servers. It provides
  CRUD operations, health status tracking, and config sync — all as a single
  supervised GenServer so that operations are serialized and crash-safe.

  ## Architecture

  This module lives in `tet_core` alongside the pure `Tet.Mcp.Server` struct.
  The runtime layer (`Tet.Runtime.Mcp.Supervisor`) consults this Registry to
  determine *which* servers to start and *when* to start them.

  Separation of concerns:
    - `Tet.Mcp.Server` — pure data, no side effects.
    - `Tet.Mcp.Registry` — stateful bookkeeping, no process supervision.
    - `Tet.Runtime.Mcp.Supervisor` — process lifecycle, delegates to Registry.

  ## Config sync

  `sync_config/1` accepts a list of server maps (or `Tet.Mcp.Server` structs)
  and reconciles them with the current state:
    - New servers (by id) are registered.
    - Existing servers have their config updated.
    - Removed servers are unregistered.

  ## Examples

      iex> {:ok, _pid} = Tet.Mcp.Registry.start_link(name: MyReg)
      iex> server = Tet.Mcp.Server.new!(%{id: "fs", command: "mcp-fs"})
      iex> :ok = Tet.Mcp.Registry.register(server, server: MyReg)
      iex> {:ok, ^server} = Tet.Mcp.Registry.lookup("fs", server: MyReg)
  """

  use GenServer

  alias Tet.Mcp.Server

  @type state :: %{
          servers: %{binary() => Server.t()},
          config_source: term()
        }

  # -- Client API --

  @doc "Starts the Registry GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Registers an MCP server.

  If a server with the same id already exists, it is replaced (last-write-wins).
  Returns `:ok` on success or `{:error, reason}` on validation failure.
  """
  @spec register(Server.t(), keyword()) :: :ok | {:error, term()}
  def register(%Server{} = server, opts \\ []) do
    server_name = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server_name, {:register, server})
  end

  @doc """
  Unregisters an MCP server by id.

  Returns `:ok` if the server was found and removed, or `{:error, :not_found}`.
  """
  @spec unregister(binary(), keyword()) :: :ok | {:error, :not_found}
  def unregister(id, opts \\ []) when is_binary(id) do
    server_name = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server_name, {:unregister, id})
  end

  @doc """
  Updates an existing MCP server's configuration.

  Only the provided fields are merged into the existing server struct.
  Returns `{:ok, updated_server}` or `{:error, reason}`.
  """
  @spec update(binary(), map(), keyword()) :: {:ok, Server.t()} | {:error, term()}
  def update(id, updates, opts \\ []) when is_binary(id) and is_map(updates) do
    server_name = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server_name, {:update, id, updates})
  end

  @doc """
  Looks up an MCP server by id.

  Returns `{:ok, server}` or `{:error, :not_found}`.
  """
  @spec lookup(binary(), keyword()) :: {:ok, Server.t()} | {:error, :not_found}
  def lookup(id, opts \\ []) when is_binary(id) do
    server_name = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server_name, {:lookup, id})
  end

  @doc "Returns all registered servers as a list."
  @spec list_all(keyword()) :: [Server.t()]
  def list_all(opts \\ []) do
    server_name = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server_name, :list_all)
  end

  @doc "Returns only servers that are startable (enabled + not errored)."
  @spec list_startable(keyword()) :: [Server.t()]
  def list_startable(opts \\ []) do
    server_name = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server_name, :list_startable)
  end

  @doc "Returns only running servers."
  @spec list_running(keyword()) :: [Server.t()]
  def list_running(opts \\ []) do
    server_name = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server_name, :list_running)
  end

  @doc """
  Updates a server's health status.

  Accepts a status atom (`:running`, `:stopped`, `:error`, `:unknown`) and
  optionally updates the heartbeat timestamp. Returns `{:ok, server}` or
  `{:error, :not_found}`.
  """
  @spec update_health(binary(), Server.status(), keyword()) ::
          {:ok, Server.t()} | {:error, :not_found} | {:error, {:invalid_status, atom()}}
  def update_health(id, status, opts \\ []) when is_binary(id) and is_atom(status) do
    server_name = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server_name, {:update_health, id, status})
  end

  @doc """
  Records a heartbeat for a running server.

  Updates `last_heartbeat` to the current UTC time. Only valid for servers
  with status `:running`. Returns `{:ok, server}` or `{:error, :not_found}`.
  """
  @spec heartbeat(binary(), keyword()) :: {:ok, Server.t()} | {:error, :not_found}
  def heartbeat(id, opts \\ []) when is_binary(id) do
    server_name = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server_name, {:heartbeat, id})
  end

  @doc """
  Syncs the registry with a list of server configurations.

  Reconciles the current server set with the provided configs:
    - New ids → register.
    - Existing ids → update config fields (preserves status/health).
    - Missing ids → unregister.

  Returns `:ok` when all configs are valid. If any config is invalid, returns
  `{:error, errors}` (a list of `{reason, raw_config}` tuples) and leaves the
  Registry unchanged.
  """
  @spec sync_config([map() | Server.t()], keyword()) :: :ok | {:error, [{term(), map()}]}
  def sync_config(configs, opts \\ []) when is_list(configs) do
    server_name = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server_name, {:sync_config, configs}, 30_000)
  end

  @doc "Returns the count of registered servers."
  @spec count(keyword()) :: non_neg_integer()
  def count(opts \\ []) do
    server_name = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server_name, :count)
  end

  # -- GenServer callbacks --

  @impl GenServer
  def init(_opts) do
    {:ok, %{servers: %{}, config_source: nil}}
  end

  @impl GenServer
  def handle_call({:register, %Server{} = server}, _from, state) do
    new_servers = Map.put(state.servers, server.id, server)
    {:reply, :ok, %{state | servers: new_servers}}
  end

  def handle_call({:unregister, id}, _from, state) do
    case Map.pop(state.servers, id) do
      {nil, _} -> {:reply, {:error, :not_found}, state}
      {_server, new_servers} -> {:reply, :ok, %{state | servers: new_servers}}
    end
  end

  def handle_call({:update, id, updates}, _from, state) do
    case Map.get(state.servers, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      server ->
        case validate_updates(server, updates) do
          {:ok, updated} ->
            new_servers = Map.put(state.servers, id, updated)
            {:reply, {:ok, updated}, %{state | servers: new_servers}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:lookup, id}, _from, state) do
    case Map.get(state.servers, id) do
      nil -> {:reply, {:error, :not_found}, state}
      server -> {:reply, {:ok, server}, state}
    end
  end

  def handle_call(:list_all, _from, state) do
    {:reply, Map.values(state.servers), state}
  end

  def handle_call(:list_startable, _from, state) do
    startable =
      state.servers
      |> Map.values()
      |> Enum.filter(&Server.startable?/1)

    {:reply, startable, state}
  end

  def handle_call(:list_running, _from, state) do
    running =
      state.servers
      |> Map.values()
      |> Enum.filter(&Server.running?/1)

    {:reply, running, state}
  end

  def handle_call({:update_health, id, status}, _from, state) do
    cond do
      status not in Server.statuses() ->
        {:reply, {:error, {:invalid_status, status}}, state}

      true ->
        case Map.get(state.servers, id) do
          nil ->
            {:reply, {:error, :not_found}, state}

          server ->
            updated = apply_health_status(server, status)
            new_servers = Map.put(state.servers, id, updated)
            {:reply, {:ok, updated}, %{state | servers: new_servers}}
        end
    end
  end

  def handle_call({:heartbeat, id}, _from, state) do
    case Map.get(state.servers, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      server ->
        updated = Server.heartbeat(server)
        new_servers = Map.put(state.servers, id, updated)
        {:reply, {:ok, updated}, %{state | servers: new_servers}}
    end
  end

  def handle_call({:sync_config, configs}, _from, state) do
    # Validate ALL configs first — if any are invalid, reject the whole batch
    parsed = Enum.map(configs, &to_server/1)

    errors =
      parsed
      |> Enum.zip(configs)
      |> Enum.reject(fn
        {{:ok, _}, _raw} -> true
        _ -> false
      end)
      |> Enum.map(fn {{:error, reason}, raw} -> {reason, raw} end)

    if errors != [] do
      {:reply, {:error, errors}, state}
    else
      incoming =
        parsed
        |> Enum.map(fn {:ok, s} -> {s.id, s} end)
        |> Map.new()

      incoming_ids = Map.keys(incoming) |> MapSet.new()
      current_ids = Map.keys(state.servers) |> MapSet.new()

      # Remove servers no longer in config
      to_remove = MapSet.difference(current_ids, incoming_ids)

      new_servers =
        Enum.reduce(to_remove, state.servers, fn id, acc ->
          Map.delete(acc, id)
        end)

      # Add or update servers from config (preserve health status for existing)
      new_servers =
        Enum.reduce(incoming, new_servers, fn {id, incoming_server}, acc ->
          case Map.get(acc, id) do
            nil ->
              # Brand new server — insert as-is
              Map.put(acc, id, incoming_server)

            existing ->
              # Existing server — update config fields, preserve health
              merged = preserve_health(incoming_server, existing)
              Map.put(acc, id, merged)
          end
        end)

      {:reply, :ok, %{state | servers: new_servers}}
    end
  end

  def handle_call(:count, _from, state) do
    {:reply, map_size(state.servers), state}
  end

  # -- Private helpers --

  defp to_server(%Server{} = server), do: {:ok, server}
  defp to_server(attrs) when is_map(attrs), do: Server.new(attrs)
  defp to_server(_), do: {:error, :invalid_config}

  defp validate_updates(server, updates) do
    # Build a candidate map from the existing server + proposed updates
    # Use explicit nil-check rather than || to preserve false values
    candidate = %{
      "id" => server.id,
      "command" => fetch_update_with_default(updates, :command, server.command),
      "args" => fetch_update_with_default(updates, :args, server.args),
      "env" => fetch_update_with_default(updates, :env, server.env),
      "enabled" => fetch_update_with_default(updates, :enabled, server.enabled),
      "health_check_interval" =>
        fetch_update_with_default(updates, :health_check_interval, server.health_check_interval)
    }

    # Validate through Server.new/1 to catch invalid values
    case Server.new(candidate) do
      {:ok, validated} ->
        # Preserve runtime state that Server.new/1 resets
        updated = %{validated | status: server.status, last_heartbeat: server.last_heartbeat}
        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_update_with_default(updates, key, default) do
    case fetch_update(updates, key) do
      nil -> default
      value -> value
    end
  end

  defp fetch_update(updates, key) do
    Map.get(updates, key, Map.get(updates, Atom.to_string(key)))
  end

  defp apply_health_status(server, :running), do: Server.mark_running(server)
  defp apply_health_status(server, :stopped), do: Server.mark_stopped(server)
  defp apply_health_status(server, :error), do: Server.mark_error(server)
  defp apply_health_status(server, :unknown), do: %{server | status: :unknown}

  defp preserve_health(incoming, existing) do
    # Update config fields from incoming, but keep status/heartbeat from existing
    %{incoming | status: existing.status, last_heartbeat: existing.last_heartbeat}
  end
end
