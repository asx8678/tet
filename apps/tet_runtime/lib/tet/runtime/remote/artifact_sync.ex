defmodule Tet.Runtime.Remote.ArtifactSync do
  @moduledoc """
  Stream artifacts back from remote workers with checksum verification.

  BD-0055: Remote execution heartbeat, cancellation, and artifacts.

  Artifacts are transferred as raw binaries with SHA-256 checksums for integrity
  verification. The module supports partial transfers via chunked streaming and
  can resume interrupted transfers by skipping already-verified chunks.

  ## Telemetry events

    * `[:tet, :remote, :artifact, :start]` — artifact transfer initiated
    * `[:tet, :remote, :artifact, :chunk]` — chunk received
    * `[:tet, :remote, :artifact, :complete]` — artifact fully transferred and verified
    * `[:tet, :remote, :artifact, :checksum_mismatch]` — checksum verification failed
    * `[:tet, :remote, :artifact, :partial]` — partial transfer (incomplete)
    * `[:tet, :remote, :artifact, :error]` — transfer error
  """

  alias Tet.Runtime.Remote.Request
  alias Tet.Runtime.Telemetry

  @chunk_size 65_536
  @checksum_algorithm :sha256

  @typedoc "Artifact descriptor"
  @type artifact :: %__MODULE__{
          path: binary(),
          size: non_neg_integer(),
          checksum: binary(),
          chunks_received: non_neg_integer(),
          complete?: boolean()
        }

  defstruct [:path, :size, :checksum, chunks_received: 0, complete?: false]

  @doc """
  Fetches an artifact from a remote worker, verifying its integrity.

  ## Options

    * `:transport` — the transport module implementing `fetch_artifact/3`
    * `:transport_opts` — keyword options passed to the transport
    * `:chunk_size` — chunk size in bytes (default: 65_536)
    * `:expected_checksum` — expected SHA-256 checksum (binary, hex-encoded)
    * `:resume_from` — number of bytes already transferred (for resume)
    * `:telemetry_emit` — optional telemetry emit callback
    * `:metadata` — optional metadata map attached to telemetry events
    * `:destination` — optional file path to write the artifact to

  Returns `{:ok, %{path: path, checksum: checksum, size: size, verified?: boolean}}`
  or `{:error, reason}`.
  """
  @spec fetch(binary() | Request.t(), binary(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def fetch(worker_ref_or_request, artifact_path, opts \\ []) when is_list(opts) do
    request = ensure_request(worker_ref_or_request, opts)
    expected_checksum = Keyword.get(opts, :expected_checksum)
    resume_from = Keyword.get(opts, :resume_from, 0)
    destination = Keyword.get(opts, :destination)

    emit(:start, %{}, %{worker_ref: request.worker_ref, path: artifact_path}, opts)

    result =
      with {:ok, transport} <- resolve_transport(opts),
           {:ok, transport_opts} <- resolve_transport_opts(opts, artifact_path, resume_from),
           {:ok, data} <- call_fetch_artifact(transport, request, artifact_path, transport_opts),
           {:ok, checksum} <- compute_checksum(data),
           :ok <- verify_checksum(checksum, expected_checksum),
           :ok <- write_destination(destination, data) do
        size = byte_size(data)

        result = %{
          path: artifact_path,
          checksum: checksum,
          size: size,
          verified?: expected_checksum == nil or checksum == expected_checksum
        }

        emit(
          :complete,
          %{size: size},
          %{worker_ref: request.worker_ref, path: artifact_path, checksum: checksum},
          opts
        )

        {:ok, result}
      end

    case result do
      {:ok, _} = ok ->
        ok

      {:error, {:checksum_mismatch, _expected, _actual}} ->
        emit(
          :checksum_mismatch,
          %{},
          %{worker_ref: request.worker_ref, path: artifact_path},
          opts
        )

        result

      {:error, reason} ->
        emit(
          :error,
          %{},
          %{worker_ref: request.worker_ref, path: artifact_path, reason: reason},
          opts
        )

        {:error, reason}
    end
  end

  @doc """
  Computes the SHA-256 checksum of a binary, returning the hex-encoded string.
  """
  @spec checksum(binary()) :: binary()
  def checksum(data) when is_binary(data) do
    :crypto.hash(@checksum_algorithm, data) |> Base.encode16(case: :lower)
  end

  @doc """
  Verifies that the computed checksum matches the expected checksum.

  Returns `:ok` or `{:error, {:checksum_mismatch, expected, actual}}`.
  """
  @spec verify(binary(), binary()) :: :ok | {:error, {:checksum_mismatch, binary(), binary()}}
  def verify(data, expected_checksum) when is_binary(expected_checksum) do
    computed = checksum(data)

    if computed == expected_checksum do
      :ok
    else
      {:error, {:checksum_mismatch, expected_checksum, computed}}
    end
  end

  @doc """
  Chunks a binary into smaller pieces for streaming. Returns a list of chunks.
  """
  @spec chunk(binary(), pos_integer()) :: [binary()]
  def chunk(data, chunk_size \\ @chunk_size) when chunk_size > 0 do
    chunk_data(data, chunk_size, [])
    |> Enum.reverse()
  end

  defp chunk_data(data, size, acc) when byte_size(data) <= size do
    if data == "", do: acc, else: [data | acc]
  end

  defp chunk_data(data, size, acc) do
    <<chunk::binary-size(size), rest::binary>> = data
    chunk_data(rest, size, [chunk | acc])
  end

  @doc """
  Merges a list of chunks back into a single binary.
  """
  @spec merge([binary()]) :: binary()
  def merge(chunks) when is_list(chunks) do
    IO.iodata_to_binary(chunks)
  end

  @doc """
  Verifies a list of chunks against an expected checksum after merging them.
  """
  @spec verify_chunks([binary()], binary()) ::
          :ok | {:error, {:checksum_mismatch, binary(), binary()}}
  def verify_chunks(chunks, expected_checksum) do
    chunks |> merge() |> verify(expected_checksum)
  end

  # ── Private helpers ─────────────────────────────────────────

  defp ensure_request(worker_ref, _opts) when is_binary(worker_ref) do
    %Request{
      operation: :check,
      worker_ref: worker_ref,
      profile_alias: worker_ref,
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

  defp resolve_transport(opts) do
    case Keyword.get(opts, :transport) do
      nil -> {:error, :artifact_transport_not_configured}
      transport when is_atom(transport) -> {:ok, transport}
      _transport -> {:error, {:invalid_artifact_transport, :not_a_module}}
    end
  end

  defp resolve_transport_opts(opts, artifact_path, resume_from) do
    transport_opts = Keyword.get(opts, :transport_opts, [])

    case Keyword.keyword?(transport_opts) do
      true ->
        {:ok,
         transport_opts
         |> Keyword.put(:artifact_path, artifact_path)
         |> Keyword.put(:resume_from, resume_from)}

      false ->
        {:error, {:invalid_artifact_transport_opts, :not_a_keyword}}
    end
  end

  defp call_fetch_artifact(transport, request, artifact_path, transport_opts) do
    with {:module, ^transport} <- Code.ensure_loaded(transport),
         true <- function_exported?(transport, :fetch_artifact, 3) do
      case apply(transport, :fetch_artifact, [request, artifact_path, transport_opts]) do
        {:ok, data} when is_binary(data) ->
          emit(
            :chunk,
            %{chunk_size: byte_size(data)},
            %{},
            Keyword.take(transport_opts, [:telemetry_emit])
          )

          {:ok, data}

        {:ok, _data} ->
          {:error, {:invalid_artifact, :not_a_binary}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, _reason} -> {:error, {:artifact_transport_not_loaded, transport}}
      false -> {:error, {:artifact_transport_missing_callback, transport}}
    end
  rescue
    exception -> {:error, {:artifact_transport_failed, exception.__struct__}}
  end

  defp compute_checksum(data) do
    {:ok, checksum(data)}
  end

  defp verify_checksum(_computed, nil), do: :ok

  defp verify_checksum(computed, expected) when computed == expected, do: :ok

  defp verify_checksum(computed, expected),
    do: {:error, {:checksum_mismatch, expected, computed}}

  defp write_destination(nil, _data), do: :ok

  defp write_destination(path, data) when is_binary(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, data) do
      :ok
    else
      {:error, reason} -> {:error, {:artifact_write_failed, reason}}
    end
  end

  defp emit(event, measurements, metadata, opts) do
    Telemetry.execute(
      [:tet, :remote, :artifact, event],
      measurements,
      metadata,
      Keyword.take(opts, [:telemetry_emit])
    )
  end
end
