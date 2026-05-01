defmodule Tet.Mcp.Server do
  @moduledoc """
  MCP server configuration as pure data.

  Represents an MCP server's identity, launch configuration, and runtime
  health status. This struct is the single source of truth for what a server
  *is* — the Registry tracks these, and the DynamicSupervisor uses them to
  decide whether to start a server process.

  ## Lifecycle

  A server transitions through statuses:
    - `:unknown`  — freshly registered, never started.
    - `:running`  — process is alive and heartbeating.
    - `:stopped`  — process was intentionally stopped.
    - `:error`    — process crashed or health check failed.

  ## Gate conditions

  The runtime supervisor only starts a server when both:
    1. `enabled` is `true`
    2. `status` is not `:error` (unknown/stopped are acceptable start states)

  This follows the project pattern: pure data in `tet_core`, runtime
  behaviour in `tet_runtime`.

  ## Examples

      iex> {:ok, s} = Tet.Mcp.Server.new(%{id: "fs", command: "mcp-filesystem", args: ["/tmp"]})
      iex> s.id
      "fs"
      iex> s.enabled
      true
      iex> s.status
      :unknown

      iex> {:ok, s} = Tet.Mcp.Server.new(%{id: "bad", command: ""})
      iex> s  # won't reach here
      ** (ArgumentError) invalid mcp server: {:invalid_command, ""}

      iex> s = Tet.Mcp.Server.new!(%{id: "git", command: "mcp-git"}) |> Tet.Mcp.Server.mark_running()
      iex> s.status
      :running
  """

  @statuses [:unknown, :running, :stopped, :error]

  @slug_regex ~r/^[a-zA-Z0-9][a-zA-Z0-9_-]*$/

  @enforce_keys [:id, :command]
  defstruct [
    :id,
    :command,
    args: [],
    env: %{},
    enabled: true,
    health_check_interval: 30_000,
    status: :unknown,
    last_heartbeat: nil
  ]

  @type status :: :unknown | :running | :stopped | :error
  @type t :: %__MODULE__{
          id: binary(),
          command: binary(),
          args: [binary()],
          env: %{binary() => binary()},
          enabled: boolean(),
          health_check_interval: non_neg_integer(),
          status: status(),
          last_heartbeat: DateTime.t() | nil
        }

  @doc "Returns the valid status atoms."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc """
  Builds a validated MCP server from a map of attributes (atom or string keys).

  Required fields:
    - `id` — unique slug identifier (non-empty, alphanumeric + `-_`)
    - `command` — executable name or path (non-empty binary)

  Optional fields:
    - `args` — list of binary arguments (default `[]`)
    - `env` — map of binary → binary environment vars (default `%{}`)
    - `enabled` — boolean (default `true`)
    - `health_check_interval` — non-negative integer ms (default `30_000`)

  Returns `{:ok, server}` or `{:error, reason}`.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- validate_id(attrs),
         {:ok, command} <- validate_command(attrs),
         {:ok, args} <- validate_args(attrs),
         {:ok, env} <- validate_env(attrs),
         {:ok, enabled} <- validate_enabled(attrs),
         {:ok, interval} <- validate_interval(attrs),
         {:ok, status} <- validate_status(attrs) do
      {:ok,
       %__MODULE__{
         id: id,
         command: command,
         args: args,
         env: env,
         enabled: enabled,
         health_check_interval: interval,
         status: status,
         last_heartbeat: nil
       }}
    end
  end

  def new(_), do: {:error, :invalid_server_attrs}

  @doc "Builds a server or raises `ArgumentError`."
  @spec new!(map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, server} -> server
      {:error, reason} -> raise ArgumentError, "invalid mcp server: #{inspect(reason)}"
    end
  end

  @doc "Returns true when the server can be started (enabled and not errored)."
  @spec startable?(t()) :: boolean()
  def startable?(%__MODULE__{enabled: true, status: status}) when status != :error, do: true
  def startable?(%__MODULE__{}), do: false

  @doc "Returns true when the server is currently running."
  @spec running?(t()) :: boolean()
  def running?(%__MODULE__{status: :running}), do: true
  def running?(%__MODULE__{}), do: false

  @doc "Returns true when the server is enabled."
  @spec enabled?(t()) :: boolean()
  def enabled?(%__MODULE__{enabled: enabled}), do: enabled == true

  @doc "Marks the server as running with a heartbeat timestamp."
  @spec mark_running(t()) :: t()
  def mark_running(%__MODULE__{} = server) do
    %{server | status: :running, last_heartbeat: DateTime.utc_now()}
  end

  @doc "Marks the server as stopped."
  @spec mark_stopped(t()) :: t()
  def mark_stopped(%__MODULE__{} = server) do
    %{server | status: :stopped}
  end

  @doc "Marks the server as errored."
  @spec mark_error(t()) :: t()
  def mark_error(%__MODULE__{} = server) do
    %{server | status: :error}
  end

  @doc "Updates the heartbeat timestamp (keeps status as :running)."
  @spec heartbeat(t()) :: t()
  def heartbeat(%__MODULE__{status: :running} = server) do
    %{server | last_heartbeat: DateTime.utc_now()}
  end

  def heartbeat(%__MODULE__{} = server), do: server

  @doc """
  Serializes a server to a plain map (string keys for JSON interop).
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = server) do
    %{
      "id" => server.id,
      "command" => server.command,
      "args" => server.args,
      "env" => server.env,
      "enabled" => server.enabled,
      "health_check_interval" => server.health_check_interval,
      "status" => to_string(server.status),
      "last_heartbeat" => server.last_heartbeat && DateTime.to_iso8601(server.last_heartbeat)
    }
  end

  # -- Validators --

  defp validate_id(attrs) do
    case fetch_value(attrs, :id) do
      id when is_binary(id) and byte_size(id) > 0 ->
        if Regex.match?(@slug_regex, id), do: {:ok, id}, else: {:error, :invalid_id}

      _ ->
        {:error, :missing_id}
    end
  end

  defp validate_command(attrs) do
    case fetch_value(attrs, :command) do
      cmd when is_binary(cmd) and byte_size(cmd) > 0 -> {:ok, cmd}
      other -> {:error, {:invalid_command, other}}
    end
  end

  defp validate_args(attrs) do
    case fetch_value(attrs, :args) do
      nil ->
        {:ok, []}

      args when is_list(args) ->
        if Enum.all?(args, &is_binary/1) do
          {:ok, args}
        else
          {:error, :invalid_args}
        end

      _ ->
        {:error, :invalid_args}
    end
  end

  defp validate_env(attrs) do
    case fetch_value(attrs, :env) do
      nil ->
        {:ok, %{}}

      env when is_map(env) ->
        if Enum.all?(env, fn {k, v} -> is_binary(k) and is_binary(v) end) do
          {:ok, env}
        else
          {:error, :invalid_env}
        end

      _ ->
        {:error, :invalid_env}
    end
  end

  defp validate_enabled(attrs) do
    case fetch_value(attrs, :enabled) do
      nil -> {:ok, true}
      true -> {:ok, true}
      false -> {:ok, false}
      _ -> {:error, :invalid_enabled}
    end
  end

  defp validate_interval(attrs) do
    case fetch_value(attrs, :health_check_interval) do
      nil -> {:ok, 30_000}
      interval when is_integer(interval) and interval >= 0 -> {:ok, interval}
      _ -> {:error, :invalid_health_check_interval}
    end
  end

  defp validate_status(attrs) do
    case fetch_value(attrs, :status) do
      nil -> {:ok, :unknown}
      status when status in @statuses -> {:ok, status}
      _ -> {:error, :invalid_status}
    end
  end

  defp fetch_value(attrs, key) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
  end
end
