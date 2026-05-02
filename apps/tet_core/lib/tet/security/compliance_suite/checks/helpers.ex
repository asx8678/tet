defmodule Tet.Security.ComplianceSuite.Checks.Helpers do
  @moduledoc """
  Shared helpers for compliance check implementations — BD-0070.
  """

  @spec run_assertions([{atom(), (-> boolean())}]) :: [map()]
  def run_assertions(tests) do
    tests
    |> Enum.flat_map(fn {name, assertion_fn} ->
      if assertion_fn.() do
        []
      else
        [%{test: name, reason: :assertion_failed}]
      end
    end)
  end

  @spec build_result(atom(), [map()], map()) :: {:ok, map()} | {:error, map()}
  def build_result(check_name, [], metadata) do
    {:ok, Map.merge(metadata, %{check: check_name, passed: true, failure_count: 0})}
  end

  def build_result(check_name, failures, metadata) do
    {:error,
     Map.merge(metadata, %{
       check: check_name,
       passed: false,
       failure_count: length(failures),
       failures: failures
     })}
  end

  @spec preview(String.t()) :: String.t()
  def preview(value) when is_binary(value) do
    if String.length(value) > 40 do
      String.slice(value, 0, 37) <> "..."
    else
      value
    end
  end

  def preview(value), do: inspect(value)
end
