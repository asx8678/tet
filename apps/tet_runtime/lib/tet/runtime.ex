defmodule Tet.Runtime do
  @moduledoc """
  Runtime command-dispatch placeholder.

  BD-0004 only reserves the OTP/runtime boundary. Real command handling,
  session workers, provider orchestration, tools, approvals, and verification
  are intentionally deferred to later backlog items.
  """

  @doc "Accepts a future core command and reports that execution is not built yet."
  def dispatch(_command) do
    {:error, :not_implemented}
  end
end
