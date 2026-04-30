defmodule Tet.Runtime.Provider.Error do
  @moduledoc """
  Shared provider error classification.

  Adapters emit normalized error events and the router decides retry/fallback from
  the same tiny truth table. Keeping this centralized avoids the classic "retry
  means three different things depending on which module had coffee" nonsense.
  """

  @retryable_kinds MapSet.new([
                     :provider_unavailable,
                     :rate_limited,
                     :network_error,
                     :timeout
                   ])

  @doc "Returns a stable, JSON-friendly error kind for provider/router reasons."
  def kind({:provider_http_status, 401, _reason, _body}), do: :auth_failed
  def kind({:provider_http_status, 403, _reason, _body}), do: :auth_failed
  def kind({:provider_http_status, 404, _reason, _body}), do: :model_not_found
  def kind({:provider_http_status, 408, _reason, _body}), do: :timeout
  def kind({:provider_http_status, 429, _reason, _body}), do: :rate_limited

  def kind({:provider_http_status, status, _reason, _body}) when status >= 500,
    do: :provider_unavailable

  def kind({:provider_http_status, _status, _reason, _body}), do: :invalid_response
  def kind({:provider_http_error, _reason}), do: :network_error
  def kind(:provider_timeout), do: :timeout
  def kind(:provider_stream_incomplete), do: :invalid_response
  def kind({:invalid_provider_chunk, _detail}), do: :invalid_response
  def kind({:invalid_provider_chunk, _payload, _detail}), do: :invalid_response
  def kind({:invalid_tool_arguments, _index, _detail}), do: :tool_args_invalid
  def kind({:missing_provider_option, _key}), do: :invalid_response
  def kind({:provider_candidate_config, _reason}), do: :configuration_error
  def kind({:unknown_provider, _provider}), do: :configuration_error
  def kind({:invalid_router_candidate, _index, _reason}), do: :configuration_error
  def kind({:invalid_router_candidates, _reason}), do: :configuration_error
  def kind(:no_provider_candidates), do: :configuration_error
  def kind(:mock_provider_error), do: :unknown
  def kind(_reason), do: :unknown

  @doc "Returns whether a provider/router reason may be retried safely."
  def retryable?(reason), do: reason |> kind() |> retryable?(reason)

  @doc "Returns whether an already-classified provider/router kind is retryable."
  def retryable?(kind, _reason), do: MapSet.member?(@retryable_kinds, kind)

  @doc "Returns a sanitized human/audit detail string."
  def detail(reason) do
    reason
    |> Tet.Redactor.redact()
    |> inspect()
  end
end
