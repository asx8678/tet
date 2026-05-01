defmodule Tet.Observability.ParityCheck do
  @moduledoc """
  Runtime parity verification for observability screens — BD-0064.

  Validates that web observability screens have CLI equivalents by
  checking module availability and parity matrix coverage. Generates
  human-readable reports for diagnostics.

  This module is pure functions. It does not dispatch tools, touch
  the filesystem, or persist events.
  """

  alias Tet.Observability.ParityMatrix

  @type result_entry :: %{
          entry: ParityMatrix.entry(),
          result: :pass | :fail | :skip,
          available: boolean()
        }

  @type run_result :: %{
          pass: [result_entry()],
          fail: [result_entry()],
          skip: [result_entry()]
        }

  @doc """
  Runs parity verification against a store module.

  Returns a map with `:pass`, `:fail`, and `:skip` lists.

  Classification rules:
  - `:implemented` + data source available → `:pass`
  - `:implemented` + data source unavailable → `:fail`
  - `:planned` → `:fail` (CLI gap exists)
  - `:not_needed` → `:skip`
  """
  @spec run(module()) :: run_result()
  def run(store_module) when is_atom(store_module) do
    verified = ParityMatrix.verify(store_module)

    results =
      Enum.map(verified, fn entry ->
        available = Map.get(entry, :available, false)
        result = classify_result(entry)
        %{entry: Map.delete(entry, :available), result: result, available: available}
      end)

    %{
      pass: Enum.filter(results, &(&1.result == :pass)),
      fail: Enum.filter(results, &(&1.result == :fail)),
      skip: Enum.filter(results, &(&1.result == :skip))
    }
  end

  @doc """
  Generates a human-readable parity report from run results.
  """
  @spec report(run_result()) :: String.t()
  def report(%{pass: pass, fail: fail, skip: skip}) do
    total = length(pass) + length(fail) + length(skip)

    [
      "Observability Parity Report",
      String.duplicate("=", 40),
      "",
      "Coverage: #{length(pass)}/#{total} passing",
      "",
      section("✅ Passing", pass),
      section("❌ Failing", fail),
      section("⏭  Skipped", skip)
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  # -- Private helpers --

  defp classify_result(%{status: :not_needed}), do: :skip
  defp classify_result(%{status: :implemented, available: true}), do: :pass
  defp classify_result(%{status: :implemented, available: false}), do: :fail
  defp classify_result(%{status: :planned}), do: :fail

  defp section(title, []), do: [title, "  (none)", ""]

  defp section(title, entries) do
    items =
      Enum.map(entries, fn %{entry: entry} ->
        "  #{entry.domain} | #{entry.web_view} → #{entry.cli_command} [#{entry.status}]"
      end)

    [title | items] ++ [""]
  end
end
