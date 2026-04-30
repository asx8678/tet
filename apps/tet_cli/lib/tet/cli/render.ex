defmodule Tet.CLI.Render do
  @moduledoc false

  def help do
    """
    tet - standalone Tet CLI scaffold

    Commands:
      tet ask PROMPT  Stream an assistant reply and persist the chat turn
      tet doctor      Check the standalone CLI/runtime/core/store boundary
      tet help        Show this help
    """
  end

  def stream_event(%Tet.Event{type: :assistant_chunk, payload: payload}) do
    Map.get(payload, :content) || Map.get(payload, "content") || ""
  end

  def stream_event(_event), do: nil

  def error(:empty_prompt), do: "prompt cannot be empty"
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

  def error({:provider_http_error, reason}) do
    "provider HTTP error: #{inspect(reason)}"
  end

  def error({:provider_http_status, status, reason_phrase, body}) do
    "provider HTTP #{status} #{reason_phrase}: #{body}"
  end

  def error(:provider_timeout), do: "provider timed out"
  def error(reason), do: inspect(reason)

  def doctor(%{profile: profile, applications: applications, store: store}) do
    application_list = applications |> Enum.map(&Atom.to_string/1) |> Enum.join(", ")
    store_status = Map.get(store, :status, :unknown)
    store_path = Map.get(store, :path, "n/a")

    """
    Tet standalone doctor: ok
    profile: #{profile}
    applications: #{application_list}
    store: #{inspect(store.adapter)} (#{store_status})
    store_path: #{store_path}
    """
  end
end
