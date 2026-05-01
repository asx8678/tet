defmodule Tet.Audit.Stream do
  @moduledoc """
  Append-only audit stream backed by ETS — BD-0069.

  The stream is a GenServer that owns a `:protected` ETS table, preventing
  external processes from bypassing the append-only API. Entries can be
  appended and queried but never updated or deleted. This is by design for
  audit integrity.

  No update or delete operations are exposed. The only mutation is `append/2`,
  which inserts a new entry. Attempting to insert a duplicate ID returns an
  error.

  When the GenServer stops, its ETS table is automatically reclaimed.

  ## Usage

      {:ok, pid} = Tet.Audit.Stream.start_link(name: :my_audit)
      {:ok, entry} = Tet.Audit.Stream.append(pid, audit_entry)
      {:ok, entries} = Tet.Audit.Stream.query(pid, session_id: "ses_1")
      3 = Tet.Audit.Stream.count(pid)
  """

  use GenServer

  alias Tet.Audit

  @filter_keys [:session_id, :event_type, :actor, :from, :to]

  # -- Public API --

  @doc "Starts a new audit stream GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    server_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, server_opts)
  end

  @doc """
  Appends an audit entry to the stream.

  Returns `{:ok, entry}` on success. Returns `{:error, :duplicate_id}` if an
  entry with the same ID already exists, and `{:error, :invalid_audit_entry}`
  if the value is not a `Tet.Audit` struct.
  """
  @spec append(GenServer.server(), Audit.t()) :: {:ok, Audit.t()} | {:error, term()}
  def append(server, %Audit{} = entry) do
    GenServer.call(server, {:append, entry})
  end

  def append(_server, _entry), do: {:error, :invalid_audit_entry}

  @doc """
  Queries audit entries by filters.

  ## Supported filters

  - `:session_id` — match session_id exactly
  - `:event_type` — match event_type atom
  - `:actor` — match actor atom
  - `:from` — entries at or after this `DateTime`
  - `:to` — entries at or before this `DateTime`

  Returns `{:ok, entries}` sorted by timestamp ascending.
  """
  @spec query(GenServer.server(), keyword()) :: {:ok, [Audit.t()]}
  def query(server, filters \\ []) do
    GenServer.call(server, {:query, filters})
  end

  @doc """
  Exports stream entries as a JSONL string.

  Accepts the same filter keys as `query/2`. Remaining options are forwarded
  to `Tet.Audit.Export.to_jsonl/2`.
  """
  @spec export(GenServer.server(), keyword()) :: {:ok, binary()}
  def export(server, opts \\ []) do
    GenServer.call(server, {:export, opts})
  end

  @doc "Returns the total number of entries in the stream."
  @spec count(GenServer.server()) :: non_neg_integer()
  def count(server) do
    GenServer.call(server, :count)
  end

  # -- GenServer callbacks --

  @impl true
  def init(opts) do
    table_name = Keyword.get(opts, :name, __MODULE__)
    table = :ets.new(:"#{table_name}_table", [:ordered_set, :protected])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:append, %Audit{} = entry}, _from, state) do
    if :ets.insert_new(state.table, {entry.id, entry.timestamp, entry}) do
      {:reply, {:ok, entry}, state}
    else
      {:reply, {:error, :duplicate_id}, state}
    end
  end

  def handle_call({:query, filters}, _from, state) do
    entries =
      state.table
      |> all_entries()
      |> apply_filters(filters)
      |> Enum.sort_by(& &1.timestamp, DateTime)

    {:reply, {:ok, entries}, state}
  end

  def handle_call({:export, opts}, _from, state) do
    {filter_keys, export_opts} = Keyword.split(opts, @filter_keys)

    entries =
      state.table
      |> all_entries()
      |> apply_filters(filter_keys)
      |> Enum.sort_by(& &1.timestamp, DateTime)

    {:reply, Audit.Export.to_jsonl(entries, export_opts), state}
  end

  def handle_call(:count, _from, state) do
    {:reply, :ets.info(state.table, :size), state}
  end

  # -- Private --

  defp all_entries(table) do
    table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, _ts, entry} -> entry end)
  end

  defp apply_filters(entries, []), do: entries

  defp apply_filters(entries, [{:session_id, sid} | rest]) do
    entries |> Enum.filter(&(&1.session_id == sid)) |> apply_filters(rest)
  end

  defp apply_filters(entries, [{:event_type, et} | rest]) do
    entries |> Enum.filter(&(&1.event_type == et)) |> apply_filters(rest)
  end

  defp apply_filters(entries, [{:actor, actor} | rest]) do
    entries |> Enum.filter(&(&1.actor == actor)) |> apply_filters(rest)
  end

  defp apply_filters(entries, [{:from, from} | rest]) do
    entries
    |> Enum.filter(&(DateTime.compare(&1.timestamp, from) != :lt))
    |> apply_filters(rest)
  end

  defp apply_filters(entries, [{:to, to} | rest]) do
    entries
    |> Enum.filter(&(DateTime.compare(&1.timestamp, to) != :gt))
    |> apply_filters(rest)
  end

  defp apply_filters(entries, [_unknown | rest]) do
    apply_filters(entries, rest)
  end
end
