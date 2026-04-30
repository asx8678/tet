defmodule Tet.Tool do
  @moduledoc """
  Pure tool-contract boundary owned by `tet_core`.

  BD-0020 intentionally defines contracts only: manifests, schemas, limits,
  redaction requirements, correlation metadata, and stable error envelopes for
  future execution layers. Runtime executors remain outside core because core is
  where side effects go to not happen. Delightfully boring, as contracts should
  be.
  """

  alias Tet.Tool.{Contract, ReadOnlyContracts}

  @doc "Returns the native read-only tool contracts known to core."
  @spec read_only_contracts() :: [Contract.t()]
  def read_only_contracts, do: ReadOnlyContracts.all()

  @doc "Fetches one native read-only tool contract by atom id, string name, or alias."
  @spec fetch_read_only_contract(atom() | binary()) ::
          {:ok, Contract.t()} | {:error, {:unknown_read_only_tool_contract, binary()}}
  def fetch_read_only_contract(name), do: ReadOnlyContracts.fetch(name)

  @doc "Returns the stable native read-only tool names exposed by the catalog."
  @spec read_only_contract_names() :: [binary()]
  def read_only_contract_names, do: ReadOnlyContracts.names()
end
