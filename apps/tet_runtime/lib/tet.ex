defmodule Tet do
  @moduledoc """
  Public runtime facade for standalone Tet clients.

  The functions here are intentionally tiny placeholders for BD-0004. Future
  backlog items can grow the implementation behind this facade while keeping
  CLI and optional adapters pointed at the same public API.
  """

  alias Tet.Runtime.{
    Autosave,
    Boundary,
    Compaction,
    Doctor,
    ModelRegistry,
    ProfileRegistry,
    PromptLab,
    Remote,
    Sessions,
    Session,
    SessionRegistry,
    Timeline
  }

  @doc "Returns the standalone boundary declared for this release profile."
  def boundary do
    Boundary.standalone()
  end

  @doc "Runs standalone health diagnostics through the public facade."
  def doctor(opts \\ []) when is_list(opts) do
    Doctor.run(opts)
  end

  @doc "Loads and validates the editable model registry."
  def model_registry(opts \\ []) when is_list(opts) do
    ModelRegistry.load(opts)
  end

  @doc "Loads and validates the editable profile registry."
  def profile_registry(opts \\ []) when is_list(opts) do
    ProfileRegistry.load(opts)
  end

  @doc "Lists configured profile descriptors as deterministic summaries."
  def list_profiles(opts \\ []) when is_list(opts) do
    ProfileRegistry.list(opts)
  end

  @doc "Fetches one configured profile descriptor by id."
  def get_profile(profile_id, opts \\ []) do
    ProfileRegistry.get(profile_id, opts)
  end

  @doc """
  Starts a runtime session process with the given profile and returns its
  session id and pid.
  """
  def start_session(workspace_ref_or_opts, opts \\ []) do
    {workspace_ref, session_opts} = normalize_start_args(workspace_ref_or_opts, opts)

    session_id = session_opts[:session_id] || Tet.Runtime.Ids.session_id()
    profile = session_opts[:profile] || "planner"

    state_opts = %{
      session_id: session_id,
      active_profile: profile
    }

    name = session_opts[:name] || {:via, Registry, {SessionRegistry.name(), session_id}}

    case Session.start_link(state_opts, name: name) do
      {:ok, pid} ->
        SessionRegistry.register(session_id, pid)

        event =
          Tet.Event.new(%{
            type: :session_started,
            session_id: session_id,
            payload: %{profile: profile, workspace_ref: workspace_ref}
          })

        case event do
          {:ok, event} ->
            Tet.EventBus.publish(Timeline.all_topic(), event)
            Tet.EventBus.publish({:session, session_id}, event)

          _ ->
            :ok
        end

        {:ok, %{session_id: session_id, pid: pid}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Requests a profile swap on a running session.

  If the session is at a safe turn boundary, the swap is applied immediately.
  If the session is mid-turn, the swap is queued (default) or rejected
  depending on the mode option.

  Returns `{:ok, state, events}` on success or `{:error, reason}` on failure.
  """
  def switch_profile(session_id_or_pid, profile, opts \\ [])
      when is_list(opts) do
    with {:ok, session} <- resolve_session(session_id_or_pid) do
      Session.request_swap(session, profile, opts)
    end
  end

  @doc "Returns the current runtime state for a session."
  def session_state(session_id_or_pid) do
    with {:ok, session} <- resolve_session(session_id_or_pid) do
      {:ok, Session.get_state(session)}
    end
  end

  @doc "Lists all running session ids."
  def list_running_sessions do
    {:ok, SessionRegistry.list_sessions()}
  end

  defp normalize_start_args(workspace_ref, opts) when is_list(opts),
    do: {workspace_ref, opts}

  defp normalize_start_args(opts, []) when is_list(opts),
    do: {nil, opts}

  defp normalize_start_args(workspace_ref, opts) when is_binary(workspace_ref) and is_list(opts),
    do: {workspace_ref, opts}

  defp resolve_session(pid) when is_pid(pid), do: {:ok, pid}

  defp resolve_session(session_id) when is_binary(session_id) do
    SessionRegistry.lookup(session_id)
  end

  defp resolve_session(_other), do: {:error, :invalid_session}

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

  @doc "Lists persisted chat sessions."
  def list_sessions(opts \\ []) do
    Sessions.list(opts)
  end

  @doc "Shows one persisted chat session and its messages."
  def show_session(session_id, opts \\ []) do
    Sessions.show(session_id, opts)
  end

  @doc "Resumes a persisted session by sending another prompt under the same id."
  def resume_session(session_id, prompt, opts \\ []) when is_binary(session_id) do
    send_prompt(session_id, prompt, opts)
  end

  @doc "Compacts persisted session context without mutating the durable message log."
  def compact_context(session_id, opts \\ []) do
    Compaction.compact_context(session_id, opts)
  end

  @doc "Autosaves a persisted session with prompt metadata and debug artifacts."
  def autosave_session(session_id, prompt_attrs, opts \\ []) do
    Autosave.save(session_id, prompt_attrs, opts)
  end

  @doc "Restores the latest autosave checkpoint for a session."
  def restore_autosave(session_id, opts \\ []) do
    Autosave.restore(session_id, opts)
  end

  @doc "Bootstraps a remote worker release through a supplied safe transport."
  @spec bootstrap_remote_worker(term(), keyword()) ::
          {:ok, Tet.Runtime.Remote.Report.t()} | {:error, term()}
  def bootstrap_remote_worker(worker_ref, opts \\ []) when is_list(opts) do
    Remote.bootstrap_worker(worker_ref, opts)
  end

  @doc "Installs or verifies a remote worker release through a supplied safe transport."
  @spec install_remote_worker(term(), keyword()) ::
          {:ok, Tet.Runtime.Remote.Report.t()} | {:error, term()}
  def install_remote_worker(worker_ref, opts \\ []) when is_list(opts) do
    Remote.install_worker(worker_ref, opts)
  end

  @doc "Checks a remote worker release through a supplied safe transport."
  @spec check_remote_worker(term(), keyword()) ::
          {:ok, Tet.Runtime.Remote.Report.t()} | {:error, term()}
  def check_remote_worker(worker_ref, opts \\ []) when is_list(opts) do
    Remote.check_worker(worker_ref, opts)
  end

  @doc "Lists autosave checkpoints, newest first."
  def list_autosaves(opts \\ []) do
    Autosave.list(opts)
  end

  @doc "Lists built-in Prompt Lab presets through the public facade."
  def prompt_lab_presets do
    PromptLab.list_presets()
  end

  @doc "Fetches one built-in Prompt Lab preset through the public facade."
  def get_prompt_lab_preset(preset_id) do
    PromptLab.get_preset(preset_id)
  end

  @doc "Refines prompt text without executing tools or sending a chat turn."
  def refine_prompt(prompt, opts \\ []) do
    PromptLab.refine(prompt, opts)
  end

  @doc "Lists Prompt Lab history entries, newest first."
  def list_prompt_history(opts \\ []) do
    PromptLab.list_history(opts)
  end

  @doc "Fetches one Prompt Lab history entry by id."
  def fetch_prompt_history(history_id, opts \\ []) do
    PromptLab.fetch_history(history_id, opts)
  end

  @doc "Lists read-only runtime timeline events, optionally filtered by session id."
  def list_events(session_id_or_opts \\ nil, opts \\ [])

  def list_events(opts, []) when is_list(opts) do
    Timeline.list_events(nil, opts)
  end

  def list_events(session_id, opts) when is_binary(session_id) or is_nil(session_id) do
    Timeline.list_events(session_id, opts)
  end

  @doc "Subscribes the caller to all future runtime timeline events."
  def subscribe_events do
    Timeline.subscribe()
  end

  @doc "Subscribes the caller to future runtime timeline events for one session."
  def subscribe_events(session_id) when is_binary(session_id) do
    Timeline.subscribe(session_id)
  end
end
