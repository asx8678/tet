defmodule Tet.Runtime.Remote.Transport do
  @moduledoc """
  Behaviour for fakeable remote-worker bootstrap transports.

  Production transport can be SSH-first later. Today the runtime only depends on
  this tiny contract, which keeps tests local and avoids a deeply cursed
  "required VPS in CI" situation.

  BD-0055 adds optional callbacks for runtime execution, cancellation, and
  artifact transfer. Transports that implement only the bootstrap callbacks
  remain fully valid — the runtime checks `function_exported?` before calling.
  """

  alias Tet.Runtime.Remote.Request

  @callback bootstrap(Request.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback install(Request.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback check(Request.t(), keyword()) :: {:ok, map()} | {:error, term()}

  @optional_callbacks execute: 2, cancel: 2, fetch_artifact: 3

  @doc """
  Execute a remote command with output streaming.

  Returns an enumerable that yields `{:stdout, binary}`, `{:stderr, binary}`,
  or `{:exit_status, non_neg_integer}` tuples.
  """
  @callback execute(Request.t(), keyword()) ::
              {:ok, Enumerable.t()} | {:error, term()}

  @doc """
  Cancel a running remote execution.

  Returns a report map with acknowledgment status.
  """
  @callback cancel(map(), keyword()) :: {:ok, map()} | {:error, term()}

  @doc """
  Fetch an artifact from a remote worker.

  Returns the raw artifact binary. The caller is responsible for checksum
  verification via `Tet.Runtime.Remote.ArtifactSync`.
  """
  @callback fetch_artifact(Request.t(), binary(), keyword()) ::
              {:ok, binary()} | {:error, term()}
end
