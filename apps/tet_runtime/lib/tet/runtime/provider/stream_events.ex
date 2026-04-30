defmodule Tet.Runtime.Provider.StreamEvents do
  @moduledoc false

  @doc "Emits the normalized provider stream-start event."
  def emit_start(provider, opts, emit, extra \\ %{}) do
    payload = provider_payload(provider, opts, extra)

    emit.(Tet.Event.provider_start(payload, event_opts(opts)))
  end

  @doc "Emits normalized text plus the legacy assistant_chunk compatibility event."
  def emit_text_delta(provider, text, opts, emit, extra \\ %{}) when is_binary(text) do
    payload = provider_payload(provider, opts, extra)

    emit.(Tet.Event.provider_text_delta(text, payload, event_opts(opts)))

    emit.(%Tet.Event{
      type: :assistant_chunk,
      session_id: Keyword.get(opts, :session_id),
      payload: Map.put(payload, :content, text),
      metadata: %{normalized_type: :provider_text_delta}
    })
  end

  @doc "Emits a normalized tool-call argument/name/id delta."
  def emit_tool_call_delta(provider, %{index: index} = delta, opts, emit) do
    arguments_delta = Map.get(delta, :arguments_delta, "")

    payload =
      provider_payload(provider, opts, %{})
      |> maybe_put(:id, Map.get(delta, :id))
      |> maybe_put(:name, Map.get(delta, :name))

    emit.(Tet.Event.provider_tool_call_delta(index, arguments_delta, payload, event_opts(opts)))
  end

  @doc "Emits a normalized completed tool-call event."
  def emit_tool_call_done(
        provider,
        %{index: index, id: id, name: name, arguments: arguments},
        opts,
        emit
      ) do
    payload = provider_payload(provider, opts, %{})

    emit.(
      Tet.Event.provider_tool_call_done(index, id, name, arguments, payload, event_opts(opts))
    )
  end

  @doc "Emits a normalized usage event."
  def emit_usage(provider, usage, opts, emit) when is_map(usage) do
    payload = provider_payload(provider, opts, %{})

    emit.(Tet.Event.provider_usage(usage, payload, event_opts(opts)))
  end

  @doc "Emits a normalized provider stream-done event."
  def emit_done(provider, stop_reason, opts, emit, extra \\ %{}) when is_atom(stop_reason) do
    payload = provider_payload(provider, opts, extra)

    emit.(Tet.Event.provider_done(stop_reason, payload, event_opts(opts)))
  end

  @doc "Emits a normalized provider error event for a returned provider error."
  def emit_error(provider, reason, opts, emit) do
    kind = error_kind(reason)

    payload =
      provider_payload(provider, opts, %{
        retryable?: retryable?(kind, reason)
      })

    emit.(Tet.Event.provider_error(kind, inspect(reason), payload, event_opts(opts)))
  end

  defp provider_payload(provider, opts, extra) do
    %{
      provider: provider,
      model: Keyword.get(opts, :model),
      request_id: Keyword.get(opts, :request_id)
    }
    |> Map.merge(extra)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp event_opts(opts) do
    [session_id: Keyword.get(opts, :session_id)]
  end

  defp maybe_put(payload, _key, nil), do: payload
  defp maybe_put(payload, _key, ""), do: payload
  defp maybe_put(payload, key, value), do: Map.put(payload, key, value)

  defp error_kind({:provider_http_status, 401, _reason, _body}), do: :auth_failed
  defp error_kind({:provider_http_status, 403, _reason, _body}), do: :auth_failed
  defp error_kind({:provider_http_status, 404, _reason, _body}), do: :model_not_found
  defp error_kind({:provider_http_status, 408, _reason, _body}), do: :timeout
  defp error_kind({:provider_http_status, 429, _reason, _body}), do: :rate_limited

  defp error_kind({:provider_http_status, status, _reason, _body}) when status >= 500,
    do: :provider_unavailable

  defp error_kind({:provider_http_status, _status, _reason, _body}), do: :invalid_response
  defp error_kind({:provider_http_error, _reason}), do: :network_error
  defp error_kind(:provider_timeout), do: :timeout
  defp error_kind(:provider_stream_incomplete), do: :invalid_response
  defp error_kind({:invalid_provider_chunk, _detail}), do: :invalid_response
  defp error_kind({:invalid_provider_chunk, _payload, _detail}), do: :invalid_response
  defp error_kind({:invalid_tool_arguments, _index, _detail}), do: :tool_args_invalid
  defp error_kind({:missing_provider_option, _key}), do: :invalid_response
  defp error_kind(:mock_provider_error), do: :unknown
  defp error_kind(_reason), do: :unknown

  defp retryable?(:provider_unavailable, _reason), do: true
  defp retryable?(:rate_limited, _reason), do: true
  defp retryable?(:network_error, _reason), do: true
  defp retryable?(:timeout, _reason), do: true
  defp retryable?(_kind, _reason), do: false
end
