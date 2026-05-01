defmodule Tet.Audit.EventBridge do
  @moduledoc """
  Bridges `Tet.Event` instances to `Tet.Audit` entries — BD-0069.

  Automatically classifies event type, action, and actor from event data.
  This bridge enables the existing event system to feed the audit stream
  without requiring changes to event producers.
  """

  alias Tet.Audit
  alias Tet.Event

  @type_mapping %{
    # Tool events
    :"tool.requested" => :tool_call,
    :"tool.started" => :tool_call,
    :"tool.finished" => :tool_call,
    :"tool.blocked" => :tool_call,
    :"read_tool.started" => :tool_call,
    :"read_tool.completed" => :tool_call,
    # Message events
    :"message.user.saved" => :message,
    :"message.assistant.saved" => :message,
    :message_persisted => :message,
    # Approval events
    :"approval.created" => :approval,
    :"approval.approved" => :approval,
    :"approval.rejected" => :approval,
    # Error events
    :"error.recorded" => :error,
    :provider_error => :error,
    # Provider lifecycle
    :provider_start => :tool_call,
    :provider_done => :tool_call,
    # Session events
    :"session.created" => :config_change,
    :"session.status_changed" => :config_change,
    :session_started => :config_change,
    :session_resumed => :config_change,
    # Workspace events
    :"workspace.created" => :config_change,
    :"workspace.trusted" => :config_change,
    # Repair / verifier events
    :"verifier.started" => :repair,
    :"verifier.finished" => :repair,
    # Patch events
    :"patch.applied" => :tool_call,
    :"patch.failed" => :error,
    # Artifact events
    :"artifact.created" => :tool_call,
    # Blocked action
    :"blocked_action.created" => :approval,
    # Finding events
    :"finding.created" => :message,
    :"finding.promoted_to_persistent_memory" => :config_change,
    :"finding.promoted_to_project_lesson" => :config_change,
    :"finding.dismissed" => :message
  }

  @doc "Returns the mapping from event types to audit event types."
  @spec event_type_mapping() :: %{atom() => Audit.event_type()}
  def event_type_mapping, do: @type_mapping

  @doc """
  Converts a `Tet.Event` to a `Tet.Audit` entry.

  Classifies event type, action, actor, and outcome automatically from the
  event's type atom and payload. Unknown event types default to `:tool_call`.
  """
  @spec from_event(Event.t()) :: {:ok, Audit.t()} | {:error, term()}
  def from_event(%Event{} = event) do
    Audit.new(%{
      id: audit_id(event),
      timestamp: normalize_timestamp(event.created_at),
      session_id: event.session_id,
      event_type: classify_event_type(event.type),
      action: classify_action(event.type),
      actor: classify_actor(event.type),
      resource: extract_resource(event),
      outcome: classify_outcome(event.type),
      metadata: event.metadata || %{},
      payload_ref: payload_ref(event)
    })
  end

  # -- Private: ID helpers --

  defp audit_id(%Event{id: id}) when is_binary(id) and id != "", do: "aud_evt_" <> id
  defp audit_id(_event), do: nil

  defp normalize_timestamp(%DateTime{} = dt), do: dt
  defp normalize_timestamp(_), do: DateTime.utc_now()

  # -- Private: classification --

  defp classify_event_type(type), do: Map.get(@type_mapping, type, :tool_call)

  defp classify_action(type) do
    s = Atom.to_string(type)

    cond do
      String.contains?(s, "created") or String.contains?(s, "saved") or
          String.contains?(s, "recorded") ->
        :create

      String.contains?(s, "approved") or String.contains?(s, "rejected") or
        String.contains?(s, "applied") or String.contains?(s, "changed") or
        String.contains?(s, "resumed") or String.contains?(s, "trusted") or
        String.contains?(s, "dismissed") or String.contains?(s, "promoted") ->
        :update

      String.starts_with?(s, "read_tool") ->
        :read

      true ->
        :execute
    end
  end

  defp classify_actor(type) do
    s = Atom.to_string(type)

    cond do
      String.starts_with?(s, "message.user") ->
        :user

      String.starts_with?(s, "message.assistant") ->
        :agent

      s in ["approval.approved", "approval.rejected"] ->
        :user

      String.starts_with?(s, "provider") ->
        :system

      String.starts_with?(s, "workspace") or String.starts_with?(s, "session") or
          String.starts_with?(s, "verifier") ->
        :system

      true ->
        :agent
    end
  end

  defp classify_outcome(type) do
    s = Atom.to_string(type)

    cond do
      String.contains?(s, "error") or String.contains?(s, "failed") -> :failure
      String.contains?(s, "blocked") or String.contains?(s, "rejected") -> :denied
      String.contains?(s, "started") or String.contains?(s, "requested") -> :pending
      true -> :success
    end
  end

  # -- Private: resource extraction --

  defp extract_resource(%Event{type: type, payload: payload}) do
    get_payload_string(payload, :file_path) ||
      get_payload_string(payload, :tool_name) ||
      get_payload_string(payload, :name) ||
      Atom.to_string(type)
  end

  defp get_payload_string(nil, _key), do: nil

  defp get_payload_string(map, key) when is_map(map) do
    case Map.get(map, key, Map.get(map, Atom.to_string(key))) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  # -- Private: payload ref --

  defp payload_ref(%Event{id: id}) when is_binary(id) and id != "", do: "payload:" <> id
  defp payload_ref(_event), do: nil
end
