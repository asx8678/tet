defmodule Tet.Prompt.Debug do
  @moduledoc false

  alias Tet.Prompt.{Canonical, Layer}

  @spec map(binary(), binary(), binary(), map(), [Layer.t()], list()) :: map()
  def map(version, id, hash, metadata, layers, messages) do
    %{
      hash: hash,
      id: id,
      layer_count: length(layers),
      layers: Enum.map(layers, &layer/1),
      message_count: length(messages),
      metadata: Tet.Redactor.redact(metadata),
      version: version
    }
  end

  @spec text(Tet.Prompt.t()) :: binary()
  def text(%Tet.Prompt{} = prompt) do
    debug = Tet.Prompt.debug(prompt)

    header = [
      "#{debug.version} id=#{debug.id} hash=#{debug.hash}",
      "layers=#{debug.layer_count} messages=#{debug.message_count} metadata=#{Canonical.encode(debug.metadata)}"
    ]

    layer_lines =
      Enum.map(debug.layers, fn layer ->
        index = layer.index |> Integer.to_string() |> String.pad_leading(3, "0")

        "#{index} #{layer.kind} role=#{layer.role} id=#{layer.id} hash=#{layer.hash} " <>
          "content_sha256=#{layer.content_sha256} bytes=#{layer.content_bytes} " <>
          "metadata=#{Canonical.encode(layer.metadata)}"
      end)

    Enum.join(header ++ layer_lines, "\n") <> "\n"
  end

  defp layer(%Layer{} = layer) do
    %{
      content_bytes: byte_size(layer.content),
      content_sha256: layer.content_sha256,
      hash: layer.hash,
      id: layer.id,
      index: layer.index,
      kind: Atom.to_string(layer.kind),
      metadata: Tet.Redactor.redact(layer.metadata),
      role: Atom.to_string(layer.role)
    }
  end
end
