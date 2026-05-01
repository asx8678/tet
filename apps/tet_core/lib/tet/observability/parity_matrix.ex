defmodule Tet.Observability.ParityMatrix do
  @moduledoc """
  Screen/CLI parity matrix for observability — BD-0064.

  Maps every web observability screen to its CLI equivalent, ensuring
  no web-only visibility gap exists. The matrix is structured data that
  can be queried, filtered, and verified at runtime.

  This module is pure data and pure functions. It does not dispatch tools,
  touch the filesystem, or persist events.
  """

  @type status :: :implemented | :planned | :not_needed
  @type domain ::
          :session | :task | :artifact | :error_log | :repair | :remote | :telemetry | :config

  @type entry :: %{
          required(:domain) => domain(),
          required(:web_view) => String.t(),
          required(:cli_command) => String.t(),
          required(:data_source) => module(),
          required(:fields) => [atom()],
          required(:status) => status()
        }

  @required_keys [:domain, :web_view, :cli_command, :data_source, :fields, :status]
  @valid_statuses [:implemented, :planned, :not_needed]
  @valid_domains [:session, :task, :artifact, :error_log, :repair, :remote, :telemetry, :config]

  @parity_entries [
    %{
      domain: :session,
      web_view: "SessionLive.Index",
      cli_command: "tet sessions",
      data_source: Tet.Store,
      fields: [:id, :status, :created_at, :task_count, :model],
      status: :implemented
    },
    %{
      domain: :session,
      web_view: "SessionLive.Show",
      cli_command: "tet session show <id>",
      data_source: Tet.Store,
      fields: [:id, :status, :created_at, :model, :provider, :message_count, :title],
      status: :implemented
    },
    %{
      domain: :task,
      web_view: "TaskLive.Index",
      cli_command: "tet tasks",
      data_source: Tet.Store,
      fields: [:id, :session_id, :title, :status, :created_at],
      status: :planned
    },
    %{
      domain: :task,
      web_view: "TaskLive.Show",
      cli_command: "tet task show <id>",
      data_source: Tet.Store,
      fields: [:id, :session_id, :title, :status, :created_at, :updated_at],
      status: :planned
    },
    %{
      domain: :artifact,
      web_view: "ArtifactLive.Index",
      cli_command: "tet artifacts",
      data_source: Tet.Store,
      fields: [:id, :session_id, :kind, :sha256, :created_at],
      status: :planned
    },
    %{
      domain: :error_log,
      web_view: "ErrorLogLive.Index",
      cli_command: "tet errors",
      data_source: Tet.Store,
      fields: [:id, :session_id, :kind, :message, :status, :created_at],
      status: :planned
    },
    %{
      domain: :error_log,
      web_view: "ErrorLogLive.Show",
      cli_command: "tet error show <id>",
      data_source: Tet.Store,
      fields: [:id, :session_id, :kind, :message, :status, :stacktrace, :created_at],
      status: :planned
    },
    %{
      domain: :repair,
      web_view: "RepairLive.Index",
      cli_command: "tet repairs",
      data_source: Tet.Store,
      fields: [:id, :error_log_id, :strategy, :status, :created_at],
      status: :planned
    },
    %{
      domain: :repair,
      web_view: "RepairLive.Show",
      cli_command: "tet repair show <id>",
      data_source: Tet.Store,
      fields: [:id, :error_log_id, :strategy, :status, :params, :result, :created_at],
      status: :planned
    },
    %{
      domain: :remote,
      web_view: "RemoteLive.Index",
      cli_command: "tet remote status",
      data_source: Tet.Store,
      fields: [:trust_level, :status, :host],
      status: :planned
    },
    %{
      domain: :telemetry,
      web_view: "TelemetryLive.Dashboard",
      cli_command: "tet doctor",
      data_source: Tet.Runtime.Doctor,
      fields: [:uptime, :memory, :processes, :store_health],
      status: :implemented
    },
    %{
      domain: :config,
      web_view: "ConfigLive.Show",
      cli_command: "tet config show",
      data_source: Tet.Core,
      fields: [:provider, :model, :workspace, :mode],
      status: :planned
    }
  ]

  @doc "Returns all parity entries."
  @spec entries() :: [entry()]
  def entries, do: @parity_entries

  @doc """
  Returns coverage stats as a map with implemented, planned, and total counts.
  """
  @spec coverage() :: %{
          implemented: non_neg_integer(),
          planned: non_neg_integer(),
          total: non_neg_integer()
        }
  def coverage do
    all = entries()
    implemented = Enum.count(all, &(&1.status == :implemented))
    planned = Enum.count(all, &(&1.status == :planned))

    %{implemented: implemented, planned: planned, total: length(all)}
  end

  @doc "Returns entries where CLI is not yet implemented."
  @spec gaps() :: [entry()]
  def gaps do
    Enum.reject(entries(), &(&1.status == :implemented))
  end

  @doc "Filters entries by domain."
  @spec for_domain(domain()) :: [entry()]
  def for_domain(domain) when domain in @valid_domains do
    Enum.filter(entries(), &(&1.domain == domain))
  end

  @doc """
  Given a store module, checks if the data sources are available.

  Returns a list of entries annotated with an `:available` boolean indicating
  whether the backing data source module is loaded. For entries whose
  `data_source` is `Tet.Store`, the provided `store_module` is checked
  instead (since `Tet.Store` is a behaviour, not a concrete adapter).
  """
  @spec verify(module()) :: [map()]
  def verify(store_module) when is_atom(store_module) do
    Enum.map(entries(), fn entry ->
      available = data_source_available?(entry, store_module)
      Map.put(entry, :available, available)
    end)
  end

  @doc "Returns required keys for parity entries."
  @spec required_keys() :: [atom()]
  def required_keys, do: @required_keys

  @doc "Returns valid statuses for parity entries."
  @spec valid_statuses() :: [status()]
  def valid_statuses, do: @valid_statuses

  @doc "Returns valid domains for parity entries."
  @spec valid_domains() :: [domain()]
  def valid_domains, do: @valid_domains

  # -- Private helpers --

  defp data_source_available?(%{data_source: Tet.Store}, store_module) do
    Code.ensure_loaded?(store_module)
  end

  defp data_source_available?(%{data_source: module}, _store_module) do
    Code.ensure_loaded?(module)
  end
end
