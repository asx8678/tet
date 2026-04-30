defmodule Tet.CLI.Render do
  @moduledoc false

  def help do
    """
    tet - standalone Tet CLI scaffold

    Commands:
      tet ask [--session SESSION_ID] PROMPT  Stream a reply and persist the chat turn
      tet sessions                         List persisted sessions
      tet session show SESSION_ID          Show a session and its messages
      tet doctor                           Check config/store/provider/release health
      tet help                             Show this help
    """
  end

  def stream_event(%Tet.Event{type: :assistant_chunk, payload: payload}) do
    Map.get(payload, :content) || Map.get(payload, "content") || ""
  end

  def stream_event(_event), do: nil

  def error(:empty_prompt), do: "prompt cannot be empty"
  def error(:empty_session_id), do: "session id cannot be empty"
  def error(:session_not_found), do: "session not found"
  def error(:autosave_not_found), do: "autosave checkpoint not found"
  def error(:store_not_configured), do: "store is not configured"

  def error({:missing_provider_env, env_name}) do
    "provider is missing required environment variable #{env_name}"
  end

  def error({:unknown_provider, provider}) do
    "unknown provider #{inspect(provider)}"
  end

  def error({:store_adapter_unavailable, adapter}) do
    "store adapter unavailable: #{inspect(adapter)}"
  end

  def error({:store_adapter_missing_callbacks, adapter, callbacks}) do
    "store adapter #{inspect(adapter)} is missing callbacks: #{Enum.join(callbacks, ", ")}"
  end

  def error({:store_unhealthy, path, reason}) do
    "store path #{path} is unhealthy: #{inspect(reason)}"
  end

  def error({:provider_http_error, reason}) do
    "provider HTTP error: #{inspect(reason)}"
  end

  def error({:provider_http_status, status, reason_phrase, body}) do
    "provider HTTP #{status} #{reason_phrase}: #{body}"
  end

  def error(:provider_timeout), do: "provider timed out"
  def error(reason), do: inspect(reason)

  def sessions([]), do: "No sessions found."

  def sessions(sessions) when is_list(sessions) do
    sessions
    |> Enum.map(&session_summary_line/1)
    |> then(&Enum.join(["Sessions:" | &1], "\n"))
  end

  def session_show(%{session: session, messages: messages}) do
    message_lines = Enum.map(messages, &message_line/1)

    [
      "Session #{session.id}",
      "messages: #{session.message_count}",
      "started_at: #{session.started_at || "n/a"}",
      "updated_at: #{session.updated_at || "n/a"}",
      "Messages:" | message_lines
    ]
    |> Enum.join("\n")
  end

  def doctor(%{profile: profile, applications: applications, store: store} = report) do
    status = Map.get(report, :status, :ok)
    application_list = applications |> Enum.map(&Atom.to_string/1) |> Enum.join(", ")
    provider = Map.get(report, :provider, %{})
    release_boundary = Map.get(report, :release_boundary, %{})
    check_lines = report |> Map.get(:checks, []) |> Enum.map(&doctor_check_line/1)

    [
      "Tet standalone doctor: #{status}",
      "profile: #{profile}",
      "applications: #{application_list}",
      "store: #{inspect(Map.get(store, :adapter))} (#{Map.get(store, :status, :unknown)})",
      "store_path: #{Map.get(store, :path, "n/a")}",
      "provider: #{inspect(Map.get(provider, :provider, :unknown))} (#{Map.get(provider, :status, :unknown)})",
      "release_boundary: #{Map.get(release_boundary, :status, :unknown)}",
      "checks:" | check_lines
    ]
    |> Enum.join("\n")
  end

  defp session_summary_line(session) do
    last =
      case {session.last_role, session.last_content} do
        {nil, _content} -> "n/a"
        {role, nil} -> Atom.to_string(role)
        {role, content} -> "#{role}: #{preview(content)}"
      end

    "  #{session.id}  messages=#{session.message_count} updated=#{session.updated_at || "n/a"} last=#{last}"
  end

  defp message_line(message) do
    "  [#{message.role}] #{indent_multiline(message.content)}"
  end

  defp doctor_check_line(%{name: name, status: status, message: message}) do
    "  [#{status}] #{name} - #{message}"
  end

  defp preview(content) do
    content
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 80)
  end

  defp indent_multiline(content) do
    String.replace(content, "\n", "\n    ")
  end
end
