defmodule Tet.Store.Memory.Registry do
  @moduledoc false

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    {:reply, Map.get(state, key), state}
  end

  @impl true
  def handle_call({:put, key, value}, _from, state) do
    {:reply, :ok, Map.put(state, key, value)}
  end

  @impl true
  def handle_call({:update, key, fun}, _from, state) do
    current = Map.get(state, key)
    {result, new_value} = fun.(current)
    {:reply, result, Map.put(state, key, new_value)}
  end

  @impl true
  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end

  # Public API for direct access (no process needed in test)
  def get(key), do: GenServer.call(__MODULE__, {:get, key})
  def put(key, value), do: GenServer.call(__MODULE__, {:put, key, value})
  def update(key, fun), do: GenServer.call(__MODULE__, {:update, key, fun})
  def state, do: GenServer.call(__MODULE__, :state)
end
