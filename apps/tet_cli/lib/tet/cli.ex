defmodule Tet.CLI do
  @moduledoc """
  Thin standalone command-line adapter.

  The CLI parses arguments, calls the public `Tet` facade, renders output, and
  returns deterministic status codes. It does not own runtime state or storage.
  """

  alias Tet.CLI.Render

  @doc "Entrypoint used by escripts and release wrappers."
  def main(argv) do
    argv
    |> run()
    |> System.halt()
  end

  @doc "Runs a CLI command and returns a process status code."
  def run(argv) when is_list(argv) do
    case argv do
      [] ->
        IO.puts(Render.help())
        0

      ["help" | _] ->
        IO.puts(Render.help())
        0

      ["--help" | _] ->
        IO.puts(Render.help())
        0

      ["doctor" | _rest] ->
        doctor()

      ["ask" | prompt_parts] ->
        ask(prompt_parts)

      [unknown | _] ->
        IO.puts(:stderr, "unknown tet command: #{unknown}")
        IO.puts(:stderr, "run `tet help` for available scaffold commands")
        64
    end
  end

  defp doctor do
    case Tet.doctor() do
      {:ok, report} ->
        IO.puts(Render.doctor(report))
        0

      {:error, reason} ->
        IO.puts(:stderr, "tet doctor failed: #{inspect(reason)}")
        1
    end
  end

  defp ask(prompt_parts) do
    prompt = prompt_parts |> Enum.join(" ") |> String.trim()

    if prompt == "" do
      IO.puts(:stderr, "usage: tet ask PROMPT")
      64
    else
      run_ask(prompt)
    end
  end

  defp run_ask(prompt) do
    on_event = fn event ->
      case Render.stream_event(event) do
        nil -> :ok
        chunk -> IO.write(chunk)
      end
    end

    case Tet.ask(prompt, on_event: on_event) do
      {:ok, _result} ->
        IO.write("\n")
        0

      {:error, reason} ->
        IO.puts(:stderr, "tet ask failed: #{Render.error(reason)}")
        1
    end
  end
end
