defmodule Tet.Runtime.Remote do
  @moduledoc """
  Runtime-owned remote worker bootstrap/check facade.

  Remote execution remains optional and less-trusted. This module only performs
  bootstrap/install/check handshakes through a supplied transport, then validates
  the worker's version, capabilities, sandbox summary, and heartbeat metadata.
  It does not execute remote tools or bypass policy/approval gates.
  """

  alias Tet.Runtime.Remote.{Protocol, Report}
  alias Tet.Runtime.Telemetry

  @doc "Bootstraps a remote worker through a configured transport."
  @spec bootstrap_worker(term(), keyword()) :: {:ok, Report.t()} | {:error, term()}
  def bootstrap_worker(worker_ref, opts \\ []) when is_list(opts) do
    perform(:bootstrap, worker_ref, opts)
  end

  @doc "Installs or verifies the remote worker release through a configured transport."
  @spec install_worker(term(), keyword()) :: {:ok, Report.t()} | {:error, term()}
  def install_worker(worker_ref, opts \\ []) when is_list(opts) do
    perform(:install, worker_ref, opts)
  end

  @doc "Checks an already-bootstrapped remote worker through a configured transport."
  @spec check_worker(term(), keyword()) :: {:ok, Report.t()} | {:error, term()}
  def check_worker(worker_ref, opts \\ []) when is_list(opts) do
    perform(:check, worker_ref, opts)
  end

  defp perform(operation, worker_ref, opts) do
    started_at = System.monotonic_time(:millisecond)

    case Protocol.build_request(operation, worker_ref, opts) do
      {:ok, request} ->
        emit_event(operation, :start, request, %{count: 1}, %{}, opts)

        result =
          with {:ok, transport} <- resolve_transport(opts),
               {:ok, transport_opts} <- transport_opts(opts),
               {:ok, raw_report} <- call_transport(transport, operation, request, transport_opts),
               {:ok, report} <- Protocol.validate_report(operation, request, raw_report) do
            {:ok, report}
          end

        emit_result(operation, request, result, started_at, opts)
        result

      {:error, reason} = error ->
        emit_rejected(operation, worker_ref, reason, started_at, opts)
        error
    end
  end

  defp resolve_transport(opts) do
    case Keyword.get(opts, :transport, Application.get_env(:tet_runtime, :remote_transport)) do
      nil -> {:error, :remote_transport_not_configured}
      transport when is_atom(transport) -> {:ok, transport}
      _transport -> {:error, {:invalid_remote_transport, :not_a_module}}
    end
  end

  defp transport_opts(opts) do
    transport_opts = Keyword.get(opts, :transport_opts, [])

    cond do
      not is_list(transport_opts) ->
        {:error, {:invalid_remote_transport_opts, :not_a_keyword}}

      Keyword.keyword?(transport_opts) ->
        case Protocol.assert_no_transport_raw_secrets(transport_opts) do
          :ok -> {:ok, transport_opts}
          {:error, reason} -> {:error, reason}
        end

      true ->
        {:error, {:invalid_remote_transport_opts, :not_a_keyword}}
    end
  end

  defp call_transport(transport, operation, request, transport_opts) do
    with {:module, ^transport} <- Code.ensure_loaded(transport),
         true <- function_exported?(transport, operation, 2) do
      case apply(transport, operation, [request, transport_opts]) do
        {:ok, raw_report} when is_map(raw_report) ->
          {:ok, raw_report}

        {:ok, _raw_report} ->
          {:error, {:invalid_remote_transport_response, operation}}

        {:error, reason} ->
          {:error, Protocol.redact_raw_secrets(reason)}

        _other ->
          {:error, {:invalid_remote_transport_response, operation}}
      end
    else
      {:error, _reason} -> {:error, {:remote_transport_not_loaded, transport}}
      false -> {:error, {:remote_transport_missing_callback, transport, operation}}
    end
  rescue
    exception ->
      {:error, {:remote_transport_failed, exception.__struct__}}
  end

  defp emit_result(operation, request, {:ok, report}, started_at, opts) do
    duration_ms = System.monotonic_time(:millisecond) - started_at

    emit_event(
      operation,
      :stop,
      request,
      %{count: 1, duration_ms: duration_ms},
      %{status: report.status, release_version: report.release_version},
      opts
    )
  end

  defp emit_result(operation, request, {:error, reason}, started_at, opts) do
    duration_ms = System.monotonic_time(:millisecond) - started_at

    emit_event(
      operation,
      :exception,
      request,
      %{count: 1, duration_ms: duration_ms},
      %{reason: Protocol.redact_raw_secrets(reason)},
      opts
    )
  end

  defp emit_rejected(operation, worker_ref, reason, started_at, opts) do
    duration_ms = System.monotonic_time(:millisecond) - started_at

    Telemetry.execute(
      [:tet, :remote, operation, :exception],
      %{count: 1, duration_ms: duration_ms},
      %{
        worker_ref: worker_ref |> inspect() |> Tet.Redactor.redact(),
        reason: Protocol.redact_raw_secrets(reason)
      },
      opts
    )
  end

  defp emit_event(operation, stage, request, measurements, extra_metadata, opts) do
    Telemetry.execute(
      [:tet, :remote, operation, stage],
      measurements,
      Map.merge(
        %{
          worker_ref: request.worker_ref,
          profile_alias: request.profile_alias,
          protocol_version: request.protocol_version
        },
        extra_metadata
      ),
      opts
    )
  end
end
