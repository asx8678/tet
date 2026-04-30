defmodule Tet.Runtime.Remote.Request do
  @moduledoc """
  Validated remote-worker bootstrap protocol request.

  Requests only carry opaque scoped secret references. The remote transport is
  responsible for resolving those references inside its own approved boundary;
  raw credentials do not belong in this struct. Capabilities carried here are
  protocol negotiation/reporting hints, not execution authorization. Tiny
  security gremlin avoided.
  """

  @enforce_keys [
    :operation,
    :worker_ref,
    :profile_alias,
    :protocol_version,
    :release_version,
    :capabilities,
    :sandbox,
    :heartbeat
  ]
  defstruct [
    :operation,
    :worker_ref,
    :profile_alias,
    :protocol_version,
    :release_version,
    capabilities: %{},
    sandbox: %{},
    heartbeat: %{},
    secret_refs: [],
    metadata: %{}
  ]

  @type operation :: :bootstrap | :install | :check
  @type t :: %__MODULE__{
          operation: operation(),
          worker_ref: binary(),
          profile_alias: binary(),
          protocol_version: binary(),
          release_version: binary(),
          capabilities: map(),
          sandbox: map(),
          heartbeat: map(),
          secret_refs: [binary()],
          metadata: map()
        }

  @doc "Converts a request to deterministic, JSON-friendly data."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = request) do
    %{
      operation: Atom.to_string(request.operation),
      worker_ref: request.worker_ref,
      profile_alias: request.profile_alias,
      protocol_version: request.protocol_version,
      release_version: request.release_version,
      capabilities: request.capabilities,
      sandbox: request.sandbox,
      heartbeat: heartbeat_to_map(request.heartbeat),
      secret_refs: request.secret_refs,
      metadata: request.metadata
    }
  end

  defp heartbeat_to_map(heartbeat) do
    Map.update!(heartbeat, :status, &Atom.to_string/1)
  end
end
