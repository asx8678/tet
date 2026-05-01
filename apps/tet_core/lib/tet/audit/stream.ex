defmodule Tet.Audit.Stream do
  @moduledoc """
  Append-only audit stream backed by ETS — BD-0069.

  The stream enforces immutability: entries can be appended and queried but
  never updated or deleted. This is by design for audit integrity.

  No update or delete operations are exposed. The only mutation is `append/2`,
  which inserts a new entry. Attempting to insert a duplicate ID returns an
  error.

  ## Usage

      Tet.Audit.Stream.init(:my_audit)
      {:ok, entry} = Tet.Audit.Stream.append(:my_audit, audit_entry)
      {:ok, entries} = Tet.Audit.Stream.query(:my_audit, session_id: "ses_1")
      3 = Tet.Audit.Stream.count(:my_audit)
  """

  alias Tet.Audit

  @filter_keys [:session_id, :event_type, :actor, :from, :to]

  @doc "Creates a new audit stream backed by a named ETS table."
  @spec init(atom()) :: :ok
  def init(name) when is_atom(name) do
    :ets.new(name, [:named_table, :ordered_set, :public])
    :ok
  end

  @doc """
  Appends an audit entry to the stream.

  Returns `{:ok, entry}` on success. Returns `{:error, :duplicate_id}` if an
  entry with the same ID already exists, and `{:error, :invalid_audit_entry}`
  if the value is not a `Tet.Audit` struct.
  """
  @spec append(atom(), Audit.t()) :: {:ok, Audit.t()} | {:error, term()}
  def append(name, %Audit{} = entry) when is_atom(name) do
    if :ets.insert_new(name, {entry.id, entry.timestamp, entry}) do
      {:ok, entry}
    else
      {:error, :duplicate_id}
    end
  end

  def append(_name, _entry), do: {:error, :invalid_audit_entry}

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
  @spec query(atom(), keyword()) :: {:ok, [Audit.t()]}
  def query(name, filters \\ []) when is_atom(name) do
    entries =
      name
      |> all_entries()
      |> apply_filters(filters)
      |> Enum.sort_by(& &1.timestamp, DateTime)

    {:ok, entries}
  end

  @doc """
  Exports stream entries as a JSONL string.

  Accepts the same filter keys as `query/2`. Remaining options are forwarded
  to `Tet.Audit.Export.to_jsonl/2`.
  """
  @spec export(atom(), keyword()) :: {:ok, binary()}
  def export(name, opts \\ []) when is_atom(name) do
    {filter_keys, export_opts} = Keyword.split(opts, @filter_keys)
    {:ok, entries} = query(name, filter_keys)
    Audit.Export.to_jsonl(entries, export_opts)
  end

  @doc "Returns the total number of entries in the stream."
  @spec count(atom()) :: non_neg_integer()
  def count(name) when is_atom(name) do
    :ets.info(name, :size)
  end

  @doc "Tears down the audit stream ETS table. For testing and cleanup only."
  @spec terminate(atom()) :: :ok
  def terminate(name) when is_atom(name) do
    :ets.delete(name)
    :ok
  end

  # -- Private --

  defp all_entries(name) do
    name
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
