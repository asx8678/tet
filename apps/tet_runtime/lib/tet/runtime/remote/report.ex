defmodule Tet.Runtime.Remote.Report do
  @moduledoc """
  Validated remote-worker bootstrap/check report.

  This is deliberately a status contract, not an execution contract. Remote
  workers are less-trusted targets; this report says what worker release was
  reached, which normalized capabilities it claims, which sandbox summary is in
  force, and what heartbeat/lease metadata the local runtime can monitor next.
  """

  @enforce_keys [
    :operation,
    :status,
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
    :status,
    :worker_ref,
    :profile_alias,
    :protocol_version,
    :release_version,
    capabilities: %{},
    sandbox: %{},
    heartbeat: %{},
    metadata: %{}
  ]

  @type status :: :ready | :installed | :checked | :degraded | :error
  @type t :: %__MODULE__{
          operation: Tet.Runtime.Remote.Request.operation(),
          status: status(),
          worker_ref: binary(),
          profile_alias: binary(),
          protocol_version: binary(),
          release_version: binary(),
          capabilities: map(),
          sandbox: map(),
          heartbeat: map(),
          metadata: map()
        }

  @doc "Converts a report to deterministic, JSON-friendly data."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = report) do
    %{
      operation: Atom.to_string(report.operation),
      status: Atom.to_string(report.status),
      worker_ref: report.worker_ref,
      profile_alias: report.profile_alias,
      protocol_version: report.protocol_version,
      release_version: report.release_version,
      capabilities: report.capabilities,
      sandbox: report.sandbox,
      heartbeat: heartbeat_to_map(report.heartbeat),
      metadata: report.metadata
    }
  end

  defp heartbeat_to_map(heartbeat) do
    Map.update!(heartbeat, :status, &Atom.to_string/1)
  end
end
