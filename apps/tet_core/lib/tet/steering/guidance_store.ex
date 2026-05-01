defmodule Tet.Steering.GuidanceStore do
  @moduledoc """
  In-memory collection management for guidance messages — BD-0033.

  Pure functions over a map of `Tet.Steering.GuidanceMessage` structs keyed
  by id. Supports adding, expiring (session-scoped), querying, and
  serializing messages. No side effects, no GenServer calls, no filesystem
  access.

  ## Lifecycle

  1. A guidance message is added via `add/2` as active (`expired: false`).
  2. When a new task/tool event arrives, `expire_by_session/2` marks all
     active messages for that session as expired.
  3. `active/1` returns only non-expired messages for rendering.
  4. Expired messages remain in the store for audit trails.

  ## Relationship to other modules

    - `Tet.Steering.GuidanceMessage` (BD-0033): the struct managed here.
    - `Tet.Runtime.GuidanceLoop` (BD-0033): runtime process that uses this
      store to manage the active guidance set.
  """

  alias Tet.Steering.GuidanceMessage

  @type store :: %{binary() => GuidanceMessage.t()}

  @doc "Returns an empty guidance store."
  @spec new() :: store()
  def new, do: %{}

  @doc """
  Adds a guidance message to the store.

  Returns the updated store. If a message with the same id already exists,
  it is replaced (last-write-wins).
  """
  @spec add(store(), GuidanceMessage.t()) :: store()
  def add(store, %GuidanceMessage{id: id} = msg) when is_map(store) do
    Map.put(store, id, msg)
  end

  @doc """
  Expires all active guidance messages for a given session.

  Other sessions' active guidance is left untouched. Returns the updated
  store.
  """
  @spec expire_by_session(store(), binary()) :: store()
  def expire_by_session(store, session_id) when is_map(store) and is_binary(session_id) do
    Map.new(store, fn {id, msg} ->
      if msg.session_id == session_id and GuidanceMessage.active?(msg) do
        {id, GuidanceMessage.expire(msg)}
      else
        {id, msg}
      end
    end)
  end

  @doc """
  Returns all non-expired (active) guidance messages.
  """
  @spec active(store()) :: [GuidanceMessage.t()]
  def active(store) when is_map(store) do
    store
    |> Enum.filter(fn {_id, msg} -> GuidanceMessage.active?(msg) end)
    |> Enum.map(fn {_id, msg} -> msg end)
  end

  @doc """
  Returns all guidance messages.
  """
  @spec all(store()) :: [GuidanceMessage.t()]
  def all(store) when is_map(store) do
    Map.values(store)
  end

  @doc """
  Returns guidance messages filtered by session_id.
  """
  @spec by_session(store(), binary()) :: [GuidanceMessage.t()]
  def by_session(store, session_id) when is_binary(session_id) do
    store
    |> Enum.filter(fn {_id, msg} -> msg.session_id == session_id end)
    |> Enum.map(fn {_id, msg} -> msg end)
  end

  @doc """
  Returns active guidance messages filtered by session_id.
  """
  @spec active_by_session(store(), binary()) :: [GuidanceMessage.t()]
  def active_by_session(store, session_id) when is_binary(session_id) do
    store
    |> active()
    |> Enum.filter(&(&1.session_id == session_id))
  end

  @doc "Returns the count of messages in the store."
  @spec count(store()) :: non_neg_integer()
  def count(store) when is_map(store), do: map_size(store)

  @doc "Returns the count of active (non-expired) messages."
  @spec active_count(store()) :: non_neg_integer()
  def active_count(store) when is_map(store) do
    store |> active() |> length()
  end

  @doc "Converts the store to a JSON-friendly list of maps."
  @spec to_list(store()) :: [map()]
  def to_list(store) when is_map(store) do
    store |> all() |> Enum.map(&GuidanceMessage.to_map/1)
  end

  @doc "Builds a store from a list of guidance message maps."
  @spec from_list([map()]) :: {:ok, store()} | {:error, term()}
  def from_list(maps) when is_list(maps) do
    results =
      Enum.reduce_while(maps, {:ok, %{}}, fn attrs, {:ok, acc} ->
        case GuidanceMessage.new(attrs) do
          {:ok, msg} -> {:cont, {:ok, Map.put(acc, msg.id, msg)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case results do
      {:ok, store} -> {:ok, store}
      {:error, reason} -> {:error, reason}
    end
  end
end
