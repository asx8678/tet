defmodule Tet.Runtime.Subagent.Accumulator do
  @moduledoc """
  GenServer that collects subagent results and produces a deterministic final
  merged result.

  ## Lifecycle

    1. Start the accumulator via `start_link/1` with the initial parent state.
    2. Subagent results are fed in via `collect/2`.
    3. When all subagents have reported, call `finalize/1` to produce the
       merged result.
    4. Check accumulation progress at any time with `status/1`.

  ## Merge strategy

  By default, results are merged using `:first_wins` strategy — earlier results
  take precedence over later ones for the same output field. Artifacts are
  always accumulated. Pass `opts` to `start_link/1` to set a different strategy.
  """

  use GenServer, restart: :transient

  alias Tet.Runtime.Subagent.ResultMerge

  # ── Client API ───────────────────────────────────────────────────────

  @doc """
  Starts the accumulator with an initial parent state.

  ## Options

    * `:merge_strategy` — one of `:first_wins`, `:last_wins`, `:merge_maps`
      (default: `:first_wins`)
    * `:on_scalar_conflict` — when using `:merge_maps`, how to resolve scalar
      conflicts (default: `:first_wins`)
    * `:name` — optional registered name for the GenServer

  The `initial_state` should be a map representing the parent runtime state
  that results will be merged into.
  """
  @spec start_link(map(), keyword()) :: GenServer.on_start()
  def start_link(initial_state, opts \\ []) when is_map(initial_state) and is_list(opts) do
    {gen_opts, accumulator_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, {initial_state, accumulator_opts}, gen_opts)
  end

  @doc """
  Collect a subagent result into the accumulator.

  The result can be a `Tet.Subagent.Result` struct or a map with the same keys.
  """
  @spec collect(GenServer.server(), map()) :: :ok
  def collect(pid, result) when is_map(result) do
    GenServer.cast(pid, {:collect, result})
  end

  @doc """
  Finalize the accumulation and produce the merged result.

  Returns `{:ok, merged_state}` where `merged_state` is the final map after
  merging all collected results.
  """
  @spec finalize(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def finalize(pid) do
    GenServer.call(pid, :finalize, :timer.seconds(10))
  end

  @doc """
  Get the current accumulation status.

  Returns `{:ok, status_map}` with:
    * `:collected_count` — number of results collected so far
    * `:finalized?` — whether the accumulator has been finalized
    * `:current_state` — the current merged state
  """
  @spec status(GenServer.server()) :: {:ok, map()}
  def status(pid) do
    GenServer.call(pid, :status)
  end

  @doc """
  Reset the accumulator back to its initial state, clearing all collected results.
  """
  @spec reset(GenServer.server()) :: :ok
  def reset(pid) do
    GenServer.cast(pid, :reset)
  end

  # ── GenServer callbacks ─────────────────────────────────────────────

  @impl true
  def init({initial_state, opts}) when is_map(initial_state) and is_list(opts) do
    merge_strategy = Keyword.get(opts, :merge_strategy, :first_wins)
    on_scalar_conflict = Keyword.get(opts, :on_scalar_conflict, :first_wins)

    state = %{
      initial_state: initial_state,
      opts: opts,
      current_state: initial_state,
      collected: [],
      collected_count: 0,
      finalized: false,
      merge_strategy: merge_strategy,
      on_scalar_conflict: on_scalar_conflict
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:collect, result}, state) do
    # Store raw results; sorting & merging happens in finalize
    {:noreply,
     %{
       state
       | collected: [result | state.collected],
         collected_count: state.collected_count + 1
     }}
  end

  @impl true
  def handle_cast(:reset, state) do
    {:ok, new_state} = init({state.initial_state, state.opts})
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:finalize, _from, state) do
    if state.finalized do
      {:reply, {:ok, state.current_state}, state}
    else
      merge_opts = [
        strategy: state.merge_strategy,
        on_scalar_conflict: state.on_scalar_conflict
      ]

      # Sort collected results by sequence/created_at, then merge sequentially
      results = Enum.reverse(state.collected)

      case ResultMerge.merge_list(state.initial_state, results, merge_opts) do
        {:ok, merged} ->
          case ResultMerge.validate(merged) do
            :ok ->
              {:reply, {:ok, merged}, %{state | current_state: merged, finalized: true}}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status_map = %{
      collected_count: state.collected_count,
      finalized?: state.finalized,
      merge_strategy: state.merge_strategy,
      current_state: state.current_state
    }

    {:reply, {:ok, status_map}, state}
  end
end
