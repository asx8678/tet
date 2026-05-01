defmodule Tet.Message do
  @moduledoc """
  Pure chat message contract shared by runtime and store adapters.

  The runtime owns message creation timing/ids. This module only validates and
  converts the stable message shape that storage adapters persist.
  """

  @roles [:system, :user, :assistant, :tool]

  @enforce_keys [:id, :session_id, :role, :content]
  defstruct [:id, :session_id, :role, :content, :timestamp, :created_at, metadata: %{}]

  @type role :: :system | :user | :assistant | :tool
  @type t :: %__MODULE__{
          id: binary(),
          session_id: binary(),
          role: role(),
          content: binary(),
          timestamp: binary() | nil,
          created_at: DateTime.t() | binary() | nil,
          metadata: map()
        }

  @doc "Returns the accepted chat message roles."
  def roles, do: @roles

  @doc "Builds a validated message struct from atom or string keyed attrs."
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- fetch_binary(attrs, :id),
         {:ok, session_id} <- fetch_binary(attrs, :session_id),
         {:ok, role} <- fetch_role(attrs),
         {:ok, content} <- fetch_binary(attrs, :content),
         {:ok, timestamp} <- fetch_optional_timestamp(attrs, :timestamp),
         {:ok, created_at} <- fetch_optional_timestamp(attrs, :created_at),
         :ok <- ensure_time_present(timestamp, created_at),
         {:ok, metadata} <- fetch_metadata(attrs) do
      {:ok,
       %__MODULE__{
         id: id,
         session_id: session_id,
         role: role,
         content: content,
         timestamp: timestamp || timestamp_value(created_at),
         created_at: created_at,
         metadata: metadata
       }}
    end
  end

  @doc "Converts a message to a JSON-friendly map with stable string roles."
  def to_map(%__MODULE__{} = message) do
    %{
      id: message.id,
      session_id: message.session_id,
      role: Atom.to_string(message.role),
      content: message.content,
      timestamp: message.timestamp,
      created_at: timestamp_value(message.created_at),
      metadata: message.metadata
    }
  end

  @doc "Converts a decoded map back to a validated message struct."
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  defp fetch_binary(attrs, key) do
    case fetch_value(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_message_field, key}}
    end
  end

  defp fetch_optional_timestamp(attrs, key) do
    case fetch_value(attrs, key) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      %DateTime{} = value -> {:ok, value}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_message_field, key}}
    end
  end

  defp ensure_time_present(nil, nil), do: {:error, {:invalid_message_field, :created_at}}
  defp ensure_time_present(_timestamp, _created_at), do: :ok

  defp timestamp_value(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp timestamp_value(value), do: value

  defp fetch_role(attrs) do
    case fetch_value(attrs, :role) do
      role when role in @roles ->
        {:ok, role}

      role when is_binary(role) ->
        role_atom = Enum.find(@roles, &(Atom.to_string(&1) == role))

        if role_atom do
          {:ok, role_atom}
        else
          {:error, {:invalid_message_role, role}}
        end

      role ->
        {:error, {:invalid_message_role, role}}
    end
  end

  defp fetch_metadata(attrs) do
    case fetch_value(attrs, :metadata, %{}) do
      metadata when is_map(metadata) -> {:ok, metadata}
      _ -> {:error, {:invalid_message_field, :metadata}}
    end
  end

  defp fetch_value(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end
end
