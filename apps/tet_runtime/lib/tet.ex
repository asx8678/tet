defmodule Tet do
  @moduledoc """
  Public runtime facade for standalone Tet clients.

  The functions here are intentionally tiny placeholders for BD-0004. Future
  backlog items can grow the implementation behind this facade while keeping
  CLI and optional adapters pointed at the same public API.
  """

  alias Tet.Runtime.{Autosave, Boundary, Doctor, Sessions}

  @doc "Returns the standalone boundary declared for this release profile."
  def boundary do
    Boundary.standalone()
  end

  @doc "Runs standalone health diagnostics through the public facade."
  def doctor(opts \\ []) when is_list(opts) do
    Doctor.run(opts)
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

  @doc "Autosaves a persisted session with prompt metadata and debug artifacts."
  def autosave_session(session_id, prompt_attrs, opts \\ []) do
    Autosave.save(session_id, prompt_attrs, opts)
  end

  @doc "Restores the latest autosave checkpoint for a session."
  def restore_autosave(session_id, opts \\ []) do
    Autosave.restore(session_id, opts)
  end

  @doc "Lists autosave checkpoints, newest first."
  def list_autosaves(opts \\ []) do
    Autosave.list(opts)
  end

  @doc "Reserved event-list facade for future durable Event Log work."
  def list_events(_session_id, _opts \\ []) do
    {:ok, []}
  end
end
