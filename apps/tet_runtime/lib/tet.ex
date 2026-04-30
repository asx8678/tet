defmodule Tet do
  @moduledoc """
  Public runtime facade for standalone Tet clients.

  The functions here are intentionally tiny placeholders for BD-0004. Future
  backlog items can grow the implementation behind this facade while keeping
  CLI and optional adapters pointed at the same public API.
  """

  alias Tet.Runtime.Boundary

  @doc "Returns the standalone boundary declared for this release profile."
  def boundary do
    Boundary.standalone()
  end

  @doc "Runs a minimal standalone health check through the public facade."
  def doctor(opts \\ []) when is_list(opts) do
    applications = Boundary.standalone_applications()

    with :ok <- Boundary.validate_standalone_applications(applications),
         {:ok, store} <- store_health(opts) do
      {:ok,
       %{
         profile: Application.get_env(:tet_runtime, :release_profile, :tet_standalone),
         applications: applications,
         core: Tet.Core.boundary(),
         runtime: %{application: :tet_runtime, status: :ok},
         store: store
       }}
    end
  end

  @doc "Starts a standalone session id for prompt turns."
  def start_session(_workspace_ref, _opts \\ []) do
    {:ok, %{session_id: Tet.Runtime.Ids.session_id()}}
  end

  @doc "Runs a single prompt turn in an existing session."
  def send_prompt(session_id, prompt, opts \\ []) when is_binary(session_id) do
    opts = Keyword.put(opts, :session_id, session_id)
    Tet.Runtime.Chat.ask(prompt, opts)
  end

  @doc "Runs a one-shot prompt turn, streaming events through `:on_event` if supplied."
  def ask(prompt, opts \\ []) do
    Tet.Runtime.Chat.ask(prompt, opts)
  end

  @doc "Lists persisted chat messages for a session."
  def list_messages(session_id, opts \\ []) do
    Tet.Runtime.Chat.list_messages(session_id, opts)
  end

  @doc "Reserved event-list facade for future durable Event Log work."
  def list_events(_session_id, _opts \\ []) do
    {:ok, []}
  end

  defp store_health(opts) do
    adapter = Keyword.get(opts, :store_adapter, Application.get_env(:tet_runtime, :store_adapter))

    cond do
      is_nil(adapter) ->
        {:ok, %{application: :none, adapter: nil, status: :not_configured}}

      Code.ensure_loaded?(adapter) and function_exported?(adapter, :health, 1) ->
        apply(adapter, :health, [opts])

      true ->
        {:error, {:store_adapter_unavailable, adapter}}
    end
  end
end
