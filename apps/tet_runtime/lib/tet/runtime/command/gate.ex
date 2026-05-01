defmodule Tet.Runtime.Command.Gate do
  @moduledoc """
  GenServer that wraps the command correction flow — BD-0048.

  Provides a runtime gate for command assessment, risk evaluation, and
  approval deferral. Commands classified as `:high` or `:critical` require
  explicit approval before execution.

  ## Flow

  1. `assess/2` — evaluates a command against the risk classifier and
     correction generator, returning a `Suggestion` with risk assessment.
  2. `require_approval?/1` — returns `true` if the suggestion's risk level
     requires gate approval (`:high` or `:critical`).
  3. `execute_or_defer/2` — if safe, executes the command; if dangerous,
     marks it as deferred for approval.

  ## Usage

      {:ok, _pid} = Tet.Runtime.Command.Gate.start_link([])

      # Assess a command
      {:ok, suggestion} = Gate.assess("rm -rf /tmp/foo", %{cwd: "/workspace"})

      # Check if approval needed
      if Gate.require_approval?(suggestion) do
        # Defer for human approval
        Gate.execute_or_defer(suggestion, %{defer: true})
      else:
        # Execute directly
        Gate.execute_or_defer(suggestion, %{execute: true})
      end
  """

  use GenServer

  alias Tet.Command.{Correction, Risk, Suggestion}

  # -- Client API --

  @doc """
  Starts the gate GenServer.

  ## Options

    * `:name` — register the GenServer under a specific name (default: `__MODULE__`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @doc """
  Assesses a command string against risk and correction policies.

  Returns `{:ok, suggestion}` where suggestion is a `Tet.Command.Suggestion`
  struct with risk level, correction, and gate requirements.

  ## Examples

      iex> {:ok, sug} = Tet.Runtime.Command.Gate.assess("ls -la", %{})
      iex> sug.risk_level
      :none
      iex> sug.requires_gate
      false

      iex> {:ok, sug} = Tet.Runtime.Command.Gate.assess("rm -rf /", %{})
      iex> sug.requires_gate
      true
  """
  @spec assess(String.t(), map()) :: {:ok, Suggestion.t()} | {:error, term()}
  def assess(command, context \\ %{}) when is_binary(command) do
    [suggestion | _] = Correction.suggest(command, context)
    {:ok, suggestion}
  end

  @doc """
  Checks if a suggestion requires explicit approval before execution.

  Returns `true` for suggestions with risk levels `:high` or `:critical`.
  """
  @spec require_approval?(Suggestion.t()) :: boolean()
  def require_approval?(%Suggestion{} = suggestion) do
    suggestion.requires_gate
  end

  @doc """
  Routes a command based on its risk assessment.

  If `opts[:defer]` is true and the suggestion requires gate approval,
  returns `{:deferred, suggestion}`. If `opts[:execute]` is true or the
  suggestion is safe, returns `{:ok, suggestion, :executed}`.

  Use this as the integration point — never bypass the gate for
  dangerous commands.
  """
  @spec execute_or_defer(Suggestion.t(), keyword()) ::
          {:ok, Suggestion.t(), :executed | :deferred} | {:error, term()}
  def execute_or_defer(%Suggestion{} = suggestion, opts \\ []) do
    cond do
      suggestion.requires_gate and Keyword.get(opts, :defer, false) ->
        {:ok, suggestion, :deferred}

      not suggestion.requires_gate ->
        {:ok, suggestion, :executed}

      Keyword.get(opts, :force, false) ->
        {:ok, suggestion, :executed}

      true ->
        {:error, {:requires_approval, "Command requires explicit approval before execution"}}
    end
  end

  @doc """
  Returns the risk level for a command string.
  """
  @spec classify(String.t()) :: :none | :low | :medium | :high | :critical
  def classify(command) when is_binary(command) do
    Risk.classify(command)
  end

  # -- GenServer callbacks --

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call({:assess, command, context}, _from, state) do
    result = assess(command, context)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:require_approval, suggestion}, _from, state) do
    {:reply, require_approval?(suggestion), state}
  end
end
