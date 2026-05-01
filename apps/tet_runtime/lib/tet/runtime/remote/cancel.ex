defmodule Tet.Runtime.Remote.Cancel do
  @moduledoc """
  Propagate cancellation to remote workers with acknowledgment tracking.

  BD-0055: Remote execution heartbeat, cancellation, and artifacts.

  Cancellation is a best-effort signal: the local runtime requests cancellation,
  waits for an acknowledgment from the remote worker (within a configurable
  timeout), and reports whether the cancellation was accepted, timed out, or
  rejected.

  ## Telemetry events

    * `[:tet, :remote, :cancel, :start]` — cancellation initiated
    * `[:tet, :remote, :cancel, :ack]` — cancellation acknowledged by worker
    * `[:tet, :remote, :cancel, :timeout]` — no acknowledgment within timeout
    * `[:tet, :remote, :cancel, :error]` — cancellation transport error
  """

  alias Tet.Runtime.Remote.Request
  alias Tet.Runtime.Telemetry

  @default_timeout_ms 10_000

  @doc """
  Sends a cancellation request to a remote worker and waits for acknowledgment.

  ## Options

    * `:timeout_ms` — how long to wait for acknowledgment (default: 10_000)
    * `:transport` — the transport module implementing `cancel/2`
    * `:transport_opts` — keyword options passed to the transport
    * `:telemetry_emit` — optional telemetry emit callback
    * `:reason` — optional cancellation reason (binary)
    * `:metadata` — optional metadata map attached to telemetry events

  Returns `{:ok, acknowledgment_map}` on success, or `{:error, reason}` on
  failure (including timeout).
  """
  @spec cancel(binary() | Request.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def cancel(worker_ref_or_request, opts \\ []) when is_list(opts) do
    started_at = System.monotonic_time(:millisecond)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    reason = Keyword.get(opts, :reason, "cancel_requested")

    request = ensure_request(worker_ref_or_request, opts)

    emit(:start, %{}, %{worker_ref: request.worker_ref, reason: reason}, opts)

    with {:ok, transport} <- resolve_transport(opts),
         {:ok, transport_opts} <- resolve_transport_opts(opts, reason),
         {:ok, cancel_request} <- build_cancel_request(request, reason, opts) do
      case call_transport_cancel(transport, cancel_request, transport_opts, timeout_ms) do
        {:ok, ack} ->
          emit(:ack, %{duration_ms: elapsed(started_at)}, %{worker_ref: request.worker_ref}, opts)
          {:ok, ack}

        {:error, :timeout} ->
          emit(
            :timeout,
            %{duration_ms: elapsed(started_at)},
            %{worker_ref: request.worker_ref},
            opts
          )

          {:error, :cancel_timeout}

        {:error, reason} ->
          emit(
            :error,
            %{duration_ms: elapsed(started_at)},
            %{worker_ref: request.worker_ref, reason: reason},
            opts
          )

          {:error, reason}
      end
    else
      {:error, reason} ->
        emit(
          :error,
          %{duration_ms: elapsed(started_at)},
          %{worker_ref: request.worker_ref, reason: reason},
          opts
        )

        {:error, reason}
    end
  end

  @doc """
  Same as `cancel/2` but accepts a raw cancel payload for transports that
  expect a minimal cancel envelope rather than a full bootstrap request.
  """
  @spec cancel_raw(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def cancel_raw(worker_ref, opts \\ []) when is_list(opts) do
    cancel(worker_ref, opts)
  end

  # ── Private helpers ─────────────────────────────────────────

  defp ensure_request(worker_ref, opts) when is_binary(worker_ref) do
    # Build a minimal request for cancellation routing
    %Request{
      operation: :check,
      worker_ref: worker_ref,
      profile_alias: Keyword.get(opts, :profile_alias, worker_ref),
      protocol_version: Tet.Runtime.Remote.Protocol.supported_protocol_version(),
      release_version: Tet.Runtime.Remote.Protocol.release_version(),
      capabilities: %{},
      sandbox: %{},
      heartbeat: %{},
      secret_refs: [],
      metadata: %{}
    }
  end

  defp ensure_request(%Request{} = request, _opts), do: request

  defp build_cancel_request(request, reason, opts) do
    metadata = Keyword.get(opts, :metadata, %{})
    lease_id = Keyword.get(opts, :lease_id)

    cancel_payload = %{
      operation: :cancel,
      worker_ref: request.worker_ref,
      profile_alias: request.profile_alias,
      protocol_version: request.protocol_version,
      release_version: request.release_version,
      reason: reason,
      metadata:
        Map.merge(metadata, %{
          lease_id: lease_id,
          sent_at_monotonic_ms: System.monotonic_time(:millisecond)
        })
    }

    {:ok, cancel_payload}
  end

  defp resolve_transport(opts) do
    case Keyword.get(opts, :transport) do
      nil -> {:error, :cancel_transport_not_configured}
      transport when is_atom(transport) -> {:ok, transport}
      _transport -> {:error, {:invalid_cancel_transport, :not_a_module}}
    end
  end

  defp resolve_transport_opts(opts, reason) do
    transport_opts = Keyword.get(opts, :transport_opts, [])

    case Keyword.keyword?(transport_opts) do
      true -> {:ok, Keyword.put(transport_opts, :cancel_reason, reason)}
      false -> {:error, {:invalid_cancel_transport_opts, :not_a_keyword}}
    end
  end

  defp call_transport_cancel(transport, cancel_request, transport_opts, timeout_ms) do
    with {:module, ^transport} <- Code.ensure_loaded(transport),
         true <- function_exported?(transport, :cancel, 2) do
      caller = self()
      ref = make_ref()

      pid =
        spawn(fn ->
          result =
            try do
              apply(transport, :cancel, [cancel_request, transport_opts])
            rescue
              exception -> {:error, {:cancel_transport_failed, exception.__struct__}}
            end

          send(caller, {ref, :cancel_result, result})
        end)

      mon_ref = Process.monitor(pid)

      receive do
        {^ref, :cancel_result, {:ok, ack}} when is_map(ack) ->
          Process.demonitor(mon_ref, [:flush])
          {:ok, ack}

        {^ref, :cancel_result, {:ok, _ack}} ->
          Process.demonitor(mon_ref, [:flush])
          {:error, {:invalid_cancel_ack, :not_a_map}}

        {^ref, :cancel_result, {:error, reason}} ->
          Process.demonitor(mon_ref, [:flush])
          {:error, reason}

        {:DOWN, ^mon_ref, :process, ^pid, reason} ->
          {:error, {:cancel_transport_exit, reason}}
      after
        timeout_ms ->
          Process.demonitor(mon_ref, [:flush])
          Process.exit(pid, :kill)
          {:error, :timeout}
      end
    else
      {:error, _reason} -> {:error, {:cancel_transport_not_loaded, transport}}
      false -> {:error, {:cancel_transport_missing_callback, transport}}
    end
  end

  defp elapsed(started_at) do
    System.monotonic_time(:millisecond) - started_at
  end

  defp emit(event, measurements, metadata, opts) do
    safe_metadata =
      metadata
      |> Map.put(:reason, safe_reason(metadata[:reason]))

    Telemetry.execute(
      [:tet, :remote, :cancel, event],
      measurements,
      safe_metadata,
      Keyword.take(opts, [:telemetry_emit])
    )
  end

  defp safe_reason(nil), do: nil
  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(reason) when is_binary(reason), do: reason

  defp safe_reason(reason) when is_tuple(reason) do
    reason |> Tuple.to_list() |> Enum.map(&safe_reason/1)
  end

  defp safe_reason(%{__struct__: mod} = exception) when is_atom(mod) do
    inspect(exception)
  end

  defp safe_reason(reason) when is_map(reason), do: reason
  defp safe_reason(reason), do: inspect(reason)
end
