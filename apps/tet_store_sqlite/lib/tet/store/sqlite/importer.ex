defmodule Tet.Store.SQLite.Importer do
  @moduledoc """
  Idempotent one-time JSONL-to-SQLite importer.

  Migrates legacy `.tet/*.jsonl` files into the SQLite store. Each import is
  tracked in the `legacy_jsonl_imports` table via SHA-256 content hashing —
  re-running is safe; already-imported files are skipped.

  ## Usage

      # Import everything from a .tet directory
      Importer.import_all("/path/to/.tet")

      # Import a single file
      Importer.import_file(:messages, "/path/to/.tet/messages.jsonl")

  ## Options

    * `:force` — re-import even if the file hash has changed (default: `false`)
    * `:batch_size` — rows per transaction batch (default: `500`)
  """

  require Logger

  alias Tet.Store.SQLite.Repo
  alias Tet.Store.SQLite.Schema.{Autosave, Event, LegacyJsonlImport, Message, PromptHistoryEntry}
  alias Tet.Store.SQLite.Schema.{Session, Workspace}

  import Ecto.Query

  @source_files %{
    messages: "messages.jsonl",
    events: "events.jsonl",
    autosaves: "autosaves.jsonl",
    prompt_history: "prompt_history.jsonl"
  }

  @default_batch_size 500
  @default_workspace_name "legacy-import"

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  @doc """
  Imports all JSONL files from a `.tet` directory.

  Returns `{:ok, %{messages: n, events: n, autosaves: n, prompt_history: n}}`
  or `{:error, reason}` on the first unrecoverable failure.
  """
  @spec import_all(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def import_all(tet_dir_path, opts \\ []) do
    results =
      Enum.reduce_while(@source_files, {:ok, %{}}, fn {kind, filename}, {:ok, acc} ->
        file_path = Path.join(tet_dir_path, filename)

        if File.exists?(file_path) do
          case import_file(kind, file_path, opts) do
            {:ok, count} -> {:cont, {:ok, Map.put(acc, kind, count)}}
            {:error, :already_imported} -> {:cont, {:ok, Map.put(acc, kind, :skipped)}}
            {:error, reason} -> {:halt, {:error, {kind, reason}}}
          end
        else
          {:cont, {:ok, Map.put(acc, kind, 0)}}
        end
      end)

    results
  end

  @doc """
  Imports a specific JSONL file into SQLite.

  Returns `{:ok, row_count}`, `{:error, :already_imported}`, or `{:error, reason}`.
  """
  @spec import_file(atom(), String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def import_file(source_kind, file_path, opts \\ [])
      when source_kind in [:messages, :events, :autosaves, :prompt_history] do
    force? = Keyword.get(opts, :force, false)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)

    with {:ok, content} <- File.read(file_path),
         {:ok, stat} <- File.stat(file_path, time: :posix),
         hash = sha256(content),
         :ok <- check_idempotency(source_kind, file_path, hash, force?) do
      lines = parse_lines(content)

      {row_count, skipped} = do_import(source_kind, lines, batch_size)

      if skipped > 0 do
        Logger.warning(
          "[Importer] #{source_kind}: imported #{row_count} rows, skipped #{skipped} malformed lines"
        )
      end

      record_import(source_kind, file_path, stat, hash, row_count)
      {:ok, row_count}
    end
  end

  # -------------------------------------------------------------------
  # Idempotency
  # -------------------------------------------------------------------

  defp check_idempotency(source_kind, file_path, hash, force?) do
    kind_str = Atom.to_string(source_kind)
    abs_path = Path.expand(file_path)

    case Repo.one(
           from(i in LegacyJsonlImport,
             where: i.source_kind == ^kind_str and i.source_path == ^abs_path
           )
         ) do
      nil ->
        :ok

      %{sha256: ^hash} ->
        {:error, :already_imported}

      _changed when force? ->
        # Force flag set — delete old record and re-import
        Repo.delete_all(
          from(i in LegacyJsonlImport,
            where: i.source_kind == ^kind_str and i.source_path == ^abs_path
          )
        )

        :ok

      _changed ->
        {:error, {:file_changed_since_last_import, source_kind, abs_path}}
    end
  end

  defp record_import(source_kind, file_path, stat, hash, row_count) do
    attrs = %{
      source_kind: Atom.to_string(source_kind),
      source_path: Path.expand(file_path),
      source_size: stat.size,
      source_mtime: stat.mtime,
      sha256: hash,
      row_count: row_count,
      imported_at: System.os_time(:second)
    }

    %LegacyJsonlImport{}
    |> LegacyJsonlImport.changeset(attrs)
    |> Repo.insert!()
  end

  # -------------------------------------------------------------------
  # Line parsing
  # -------------------------------------------------------------------

  defp parse_lines(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode/1)
  end

  # -------------------------------------------------------------------
  # Import dispatch
  # -------------------------------------------------------------------

  defp do_import(:messages, lines, batch_size), do: import_messages(lines, batch_size)
  defp do_import(:events, lines, batch_size), do: import_events(lines, batch_size)
  defp do_import(:autosaves, lines, batch_size), do: import_autosaves(lines, batch_size)
  defp do_import(:prompt_history, lines, batch_size), do: import_prompt_history(lines, batch_size)

  # -------------------------------------------------------------------
  # Messages
  # -------------------------------------------------------------------

  defp import_messages(lines, batch_size) do
    {messages, skipped} = parse_structs(lines, &Tet.Message.from_map/1)

    grouped = Enum.group_by(messages, & &1.session_id)
    workspace_id = ensure_default_workspace()

    row_count =
      Enum.reduce(grouped, 0, fn {session_id, session_messages}, total ->
        ensure_session(session_id, session_messages, workspace_id)
        attrs_list = build_message_attrs(session_messages)

        batch_insert(attrs_list, batch_size, fn batch ->
          Repo.insert_all(Message, batch, on_conflict: :nothing)
        end)

        total + length(attrs_list)
      end)

    {row_count, skipped}
  end

  defp build_message_attrs(messages) do
    messages
    |> Enum.sort_by(&(&1.timestamp || &1.created_at || ""))
    |> Enum.with_index(1)
    |> Enum.map(fn {msg, seq} -> Message.from_core_struct(msg, seq: seq) end)
  end

  # -------------------------------------------------------------------
  # Events
  # -------------------------------------------------------------------

  defp import_events(lines, batch_size) do
    {events, skipped} = parse_structs(lines, &Tet.Event.from_map/1)

    grouped = Enum.group_by(events, & &1.session_id)
    workspace_id = ensure_default_workspace()

    row_count =
      Enum.reduce(grouped, 0, fn {session_id, session_events}, total ->
        if session_id, do: ensure_session_minimal(session_id, workspace_id)

        attrs_list = build_event_attrs(session_events)

        batch_insert(attrs_list, batch_size, fn batch ->
          Repo.insert_all(Event, batch, on_conflict: :nothing)
        end)

        total + length(attrs_list)
      end)

    {row_count, skipped}
  end

  defp build_event_attrs(events) do
    events
    |> assign_sequences()
    |> Enum.map(fn event ->
      event
      |> ensure_event_id()
      |> Event.from_core_struct()
    end)
  end

  defp assign_sequences(events) do
    events
    |> Enum.with_index(1)
    |> Enum.map(fn {event, idx} ->
      seq = event.seq || event.sequence || idx
      %{event | seq: seq, sequence: seq}
    end)
  end

  defp ensure_event_id(%Tet.Event{id: nil} = event) do
    %{event | id: generate_id("evt")}
  end

  defp ensure_event_id(event), do: event

  # -------------------------------------------------------------------
  # Autosaves
  # -------------------------------------------------------------------

  defp import_autosaves(lines, batch_size) do
    {autosaves, skipped} = parse_structs(lines, &Tet.Autosave.from_map/1)

    workspace_id = ensure_default_workspace()

    attrs_list =
      Enum.map(autosaves, fn autosave ->
        ensure_session_minimal(autosave.session_id, workspace_id)
        Autosave.from_core_struct(autosave)
      end)

    batch_insert(attrs_list, batch_size, fn batch ->
      Repo.insert_all(Autosave, batch, on_conflict: :nothing)
    end)

    {length(attrs_list), skipped}
  end

  # -------------------------------------------------------------------
  # Prompt History
  # -------------------------------------------------------------------

  defp import_prompt_history(lines, batch_size) do
    {entries, skipped} = parse_structs(lines, &Tet.PromptLab.HistoryEntry.from_map/1)

    attrs_list = Enum.map(entries, &PromptHistoryEntry.from_core_struct/1)

    batch_insert(attrs_list, batch_size, fn batch ->
      Repo.insert_all(PromptHistoryEntry, batch, on_conflict: :nothing)
    end)

    {length(attrs_list), skipped}
  end

  # -------------------------------------------------------------------
  # Session & Workspace helpers
  # -------------------------------------------------------------------

  defp ensure_default_workspace do
    now = System.os_time(:second)

    case Repo.one(from(w in Workspace, where: w.name == @default_workspace_name, limit: 1)) do
      %{id: id} ->
        id

      nil ->
        id = generate_id("ws")

        attrs = %{
          id: id,
          name: @default_workspace_name,
          root_path: ".",
          tet_dir_path: ".tet",
          trust_state: "trusted",
          metadata: "{}",
          created_at: now,
          updated_at: now
        }

        %Workspace{}
        |> Workspace.changeset(attrs)
        |> Repo.insert!()

        id
    end
  end

  defp ensure_session(session_id, messages, workspace_id) do
    case Repo.get(Session, session_id) do
      nil ->
        insert_session_from_messages(session_id, messages, workspace_id)

      _existing ->
        :ok
    end
  end

  defp ensure_session_minimal(session_id, workspace_id) do
    case Repo.get(Session, session_id) do
      nil -> insert_minimal_session(session_id, workspace_id)
      _existing -> :ok
    end
  end

  defp insert_session_from_messages(session_id, messages, workspace_id) do
    case Tet.Session.from_messages(session_id, messages) do
      {:ok, session} ->
        core = %{session | workspace_id: workspace_id}
        insert_session_row(core)

      {:error, _} ->
        insert_minimal_session(session_id, workspace_id)
    end
  end

  defp insert_minimal_session(session_id, workspace_id) do
    now = System.os_time(:second)

    attrs = %{
      id: session_id,
      workspace_id: workspace_id,
      short_id: String.slice(session_id, 0, 8),
      mode: "chat",
      status: "complete",
      created_at: now,
      started_at: now,
      updated_at: now,
      metadata: "{}"
    }

    %Session{}
    |> Session.changeset(attrs)
    |> Repo.insert!(on_conflict: :nothing)
  end

  defp insert_session_row(%Tet.Session{} = session) do
    now_iso = DateTime.utc_now() |> DateTime.to_iso8601()

    session = %{
      session
      | short_id: session.short_id || String.slice(session.id, 0, 8),
        mode: session.mode || :chat,
        status: session.status || :complete,
        created_at: session.created_at || now_iso,
        started_at: session.started_at || session.created_at || now_iso,
        updated_at: session.updated_at || now_iso
    }

    attrs = Session.from_core_struct(session)

    %Session{}
    |> Session.changeset(attrs)
    |> Repo.insert!(on_conflict: :nothing)
  end

  # -------------------------------------------------------------------
  # Batch & parsing helpers
  # -------------------------------------------------------------------

  defp parse_structs(lines, parse_fn) do
    Enum.reduce(lines, {[], 0}, fn
      {:ok, map}, {acc, skipped} ->
        case parse_fn.(map) do
          {:ok, struct} -> {[struct | acc], skipped}
          {:error, _} -> {acc, skipped + 1}
        end

      {:error, _}, {acc, skipped} ->
        {acc, skipped + 1}
    end)
    |> then(fn {items, skipped} -> {Enum.reverse(items), skipped} end)
  end

  defp batch_insert(attrs_list, batch_size, insert_fn) do
    attrs_list
    |> Enum.chunk_every(batch_size)
    |> Enum.each(fn batch ->
      Repo.transaction(fn -> insert_fn.(batch) end)
    end)
  end

  # -------------------------------------------------------------------
  # Utilities
  # -------------------------------------------------------------------

  defp sha256(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end

  defp generate_id(prefix) do
    random = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    "#{prefix}-#{random}"
  end
end
