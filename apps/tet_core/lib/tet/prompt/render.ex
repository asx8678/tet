defmodule Tet.Prompt.Render do
  @moduledoc false

  def compaction(summary, source_message_ids, strategy, original_count, retained_count) do
    details =
      []
      |> append_detail("strategy", strategy)
      |> append_detail("original_message_count", original_count)
      |> append_detail("retained_message_count", retained_count)
      |> append_detail("source_message_ids", join_ids(source_message_ids))

    lines = ["Compaction summary:", summary]

    if details == [] do
      Enum.join(lines, "\n")
    else
      Enum.join(lines ++ ["", "Compaction metadata:"] ++ Enum.reverse(details), "\n")
    end
  end

  def attachments(attachments) do
    ["Attachment metadata:"]
    |> Kernel.++(Enum.flat_map(attachments, &attachment_lines/1))
    |> Enum.join("\n")
  end

  defp attachment_lines(attachment) do
    ["- id: #{attachment.id}"]
    |> append_attachment_line("name", Map.get(attachment, :name))
    |> append_attachment_line("media_type", Map.get(attachment, :media_type))
    |> append_attachment_line("byte_size", Map.get(attachment, :byte_size))
    |> append_attachment_line("sha256", Map.get(attachment, :sha256))
    |> append_attachment_line("source", Map.get(attachment, :source))
    |> Enum.reverse()
  end

  defp append_detail(details, _key, nil), do: details
  defp append_detail(details, _key, ""), do: details
  defp append_detail(details, key, value), do: ["- #{key}: #{value}" | details]

  defp join_ids([]), do: nil
  defp join_ids(ids), do: Enum.join(ids, ", ")

  defp append_attachment_line(lines, _key, nil), do: lines
  defp append_attachment_line(lines, key, value), do: ["  #{key}: #{value}" | lines]
end
