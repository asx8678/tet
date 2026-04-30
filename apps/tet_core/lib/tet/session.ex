defmodule Tet.Session do
  @moduledoc """
  Pure persisted-session summary shared by runtime, CLI renderers, and stores.

  The store owns discovery/query mechanics; this struct only captures the stable
  summary shape callers can render without learning a storage format.
  """

  @enforce_keys [:id]
  defstruct [
    :id,
    :started_at,
    :updated_at,
    :last_role,
    :last_content,
    message_count: 0,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: binary(),
          started_at: binary() | nil,
          updated_at: binary() | nil,
          last_role: Tet.Message.role() | nil,
          last_content: binary() | nil,
          message_count: non_neg_integer(),
          metadata: map()
        }

  @doc "Builds a validated session summary from atom or string keyed attrs."
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- fetch_binary(attrs, :id),
         {:ok, started_at} <- fetch_optional_binary(attrs, :started_at),
         {:ok, updated_at} <- fetch_optional_binary(attrs, :updated_at),
         {:ok, last_role} <- fetch_optional_role(attrs, :last_role),
         {:ok, last_content} <- fetch_optional_binary(attrs, :last_content),
         {:ok, message_count} <- fetch_message_count(attrs),
         {:ok, metadata} <- fetch_metadata(attrs) do
      {:ok,
       %__MODULE__{
         id: id,
         started_at: started_at,
         updated_at: updated_at,
         last_role: last_role,
         last_content: last_content,
         message_count: message_count,
         metadata: metadata
       }}
    end
  end

  @doc "Builds a summary for one session from messages already returned in order."
  def from_messages(session_id, messages) when is_binary(session_id) and is_list(messages) do
    case Enum.filter(messages, &(&1.session_id == session_id)) do
      [] ->
        {:error, :session_not_found}

      session_messages ->
        first = List.first(session_messages)
        last = List.last(session_messages)

        new(%{
          id: session_id,
          started_at: first.timestamp,
          updated_at: last.timestamp,
          last_role: last.role,
          last_content: last.content,
          message_count: length(session_messages)
        })
    end
  end

  @doc "Converts the summary to a JSON-friendly map."
  def to_map(%__MODULE__{} = session) do
    %{
      id: session.id,
      started_at: session.started_at,
      updated_at: session.updated_at,
      last_role: role_to_string(session.last_role),
      last_content: session.last_content,
      message_count: session.message_count,
      metadata: session.metadata
    }
  end

  defp fetch_message_count(attrs) do
    case fetch_value(attrs, :message_count, 0) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> {:error, {:invalid_session_field, :message_count}}
    end
  end

  defp fetch_metadata(attrs) do
    case fetch_value(attrs, :metadata, %{}) do
      metadata when is_map(metadata) -> {:ok, metadata}
      _ -> {:error, {:invalid_session_field, :metadata}}
    end
  end

  defp fetch_binary(attrs, key) do
    case fetch_value(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_session_field, key}}
    end
  end

  defp fetch_optional_binary(attrs, key) do
    case fetch_value(attrs, key) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_session_field, key}}
    end
  end

  defp fetch_optional_role(attrs, key) do
    case fetch_value(attrs, key) do
      nil ->
        {:ok, nil}

      role when is_atom(role) ->
        if role in Tet.Message.roles() do
          {:ok, role}
        else
          {:error, {:invalid_session_role, role}}
        end

      role when is_binary(role) ->
        case Enum.find(Tet.Message.roles(), &(Atom.to_string(&1) == role)) do
          nil -> {:error, {:invalid_session_role, role}}
          role_atom -> {:ok, role_atom}
        end

      role ->
        {:error, {:invalid_session_role, role}}
    end
  end

  defp fetch_value(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp role_to_string(nil), do: nil
  defp role_to_string(role), do: Atom.to_string(role)
end
