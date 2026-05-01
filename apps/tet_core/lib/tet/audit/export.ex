defmodule Tet.Audit.Export do
  @moduledoc """
  JSONL export and import for audit entries — BD-0069.

  All exports apply redaction before serialization. Raw secrets never appear in
  exported JSONL. The format is append-only: each line is a self-contained JSON
  object representing one audit entry.
  """

  alias Tet.Audit

  @doc """
  Exports audit entries to a JSONL format string.

  Each entry is redacted, then serialized as one JSON object per line.
  Returns `{:ok, jsonl}` where `jsonl` is the JSONL string.
  """
  @spec to_jsonl([Audit.t()], keyword()) :: {:ok, binary()}
  def to_jsonl(entries, _opts \\ []) when is_list(entries) do
    jsonl =
      entries
      |> Enum.map(&entry_to_json_line/1)
      |> Enum.join("\n")

    result = if jsonl == "", do: "", else: jsonl <> "\n"
    {:ok, result}
  end

  @doc """
  Exports audit entries to a file path in append-only mode.

  Opens the file for append and writes each redacted entry as a JSONL line.
  Creates the file if it does not exist. Never truncates existing content.
  """
  @spec to_file([Audit.t()], Path.t(), keyword()) :: :ok | {:error, term()}
  def to_file(entries, path, _opts \\ []) when is_list(entries) and is_binary(path) do
    case to_jsonl(entries) do
      {:ok, ""} -> :ok
      {:ok, jsonl} -> File.write(path, jsonl, [:append])
    end
  end

  @doc """
  Parses a JSONL string back to audit entries.

  Returns `{:ok, entries}` containing only successfully parsed lines.
  Invalid lines are silently skipped.
  """
  @spec from_jsonl(binary()) :: {:ok, [Audit.t()]}
  def from_jsonl(jsonl) when is_binary(jsonl) do
    entries =
      jsonl
      |> String.split("\n", trim: true)
      |> Enum.reduce([], fn line, acc ->
        case parse_line(line) do
          {:ok, entry} -> [entry | acc]
          {:error, _} -> acc
        end
      end)
      |> Enum.reverse()

    {:ok, entries}
  end

  # -- Private --

  defp entry_to_json_line(%Audit{} = entry) do
    entry
    |> Audit.redact()
    |> Audit.to_map()
    |> Jason.encode!()
  end

  defp parse_line(line) do
    with {:ok, map} <- Jason.decode(line) do
      Audit.from_map(map)
    end
  end
end
