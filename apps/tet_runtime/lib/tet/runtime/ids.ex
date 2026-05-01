defmodule Tet.Runtime.Ids do
  @moduledoc false

  def session_id, do: "ses_" <> unique_suffix()
  def message_id, do: "msg_" <> unique_suffix()
  def request_id, do: "req_" <> unique_suffix()
  def swap_id, do: "swp_" <> unique_suffix()

  def timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:millisecond)
    |> DateTime.to_iso8601()
  end

  defp unique_suffix do
    time = System.system_time(:microsecond) |> Integer.to_string(36)
    unique = System.unique_integer([:positive, :monotonic]) |> Integer.to_string(36)

    time <> "_" <> unique
  end
end
