defmodule TetWebPhoenix.EventProjection do
  @moduledoc false

  @marker_keys [:dashboard, :domain, :category, :kind, :topic, :stream, :area]
  @summary_keys [:summary, :message, :detail, :reason, :content, :text, :path, :name, :title]

  def row(%Tet.Event{} = event, extra_fields \\ []) when is_list(extra_fields) do
    fields =
      Map.new(extra_fields, fn {field, keys} ->
        {field, event |> event_value(List.wrap(keys)) |> format()}
      end)

    base = %{
      ref: event_ref(event),
      sequence: event.sequence,
      sequence_label: format_sequence(event.sequence),
      session_id: event.session_id,
      session_label: event.session_id || "n/a",
      type: type_name(event.type),
      timestamp: event |> event_value([:timestamp], [:metadata, :payload]) |> format(),
      summary: summary(event),
      payload: event.payload || %{},
      metadata: event.metadata || %{},
      fields: fields
    }

    Map.merge(base, fields)
  end

  def event_value(%Tet.Event{} = event, keys, sources \\ [:payload, :metadata])
      when is_list(keys) do
    sources
    |> Enum.find_value(fn source ->
      event
      |> source_map(source)
      |> first_present(keys)
    end)
  end

  def has_any_key?(%Tet.Event{} = event, keys) when is_list(keys) do
    Enum.any?(keys, fn key ->
      present?(value(event.payload, key)) or present?(value(event.metadata, key))
    end)
  end

  def marked?(%Tet.Event{} = event, markers) when is_list(markers) do
    markers = Enum.map(markers, &marker/1)

    event
    |> marker_values()
    |> Enum.any?(&marker_match?(&1, markers))
  end

  def type_contains?(%Tet.Event{type: type}, needle) when is_binary(needle) do
    type
    |> type_name()
    |> String.contains?(needle)
  end

  def format(nil), do: "n/a"
  def format(""), do: "n/a"

  def format(value) when is_binary(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 160)
  end

  def format(value) when is_atom(value), do: Atom.to_string(value)
  def format(value) when is_boolean(value), do: to_string(value)
  def format(value) when is_integer(value), do: Integer.to_string(value)
  def format(value) when is_float(value), do: Float.to_string(value)

  def format(value) do
    inspect(value, printable_limit: 160, limit: 20)
  end

  defp source_map(%Tet.Event{payload: payload}, :payload), do: payload || %{}
  defp source_map(%Tet.Event{metadata: metadata}, :metadata), do: metadata || %{}

  defp first_present(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      case value(map, key) do
        value when value in [nil, "", []] -> nil
        value -> value
      end
    end)
  end

  defp value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp value(map, key) when is_map(map) and is_binary(key), do: Map.get(map, key)
  defp value(_map, _key), do: nil

  defp present?(value), do: value not in [nil, "", []]

  defp marker_values(%Tet.Event{} = event) do
    Enum.flat_map(@marker_keys, fn key ->
      [value(event.payload, key), value(event.metadata, key)]
    end)
  end

  defp marker_match?(nil, _markers), do: false

  defp marker_match?(values, markers) when is_list(values) do
    Enum.any?(values, &marker_match?(&1, markers))
  end

  defp marker_match?(value, markers) do
    marker(value) in markers
  end

  defp marker(value) do
    value
    |> format()
    |> String.downcase()
  end

  defp summary(%Tet.Event{} = event) do
    case event_value(event, @summary_keys) do
      nil -> payload_summary(event.payload || %{})
      value -> format(value)
    end
  end

  defp payload_summary(payload) when map_size(payload) == 0, do: ""

  defp payload_summary(payload) do
    payload
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.take(4)
    |> Enum.map(fn {key, value} -> "#{key}=#{format(value)}" end)
    |> Enum.join(" ")
  end

  defp event_ref(%Tet.Event{sequence: sequence}) when is_integer(sequence),
    do: "event-#{sequence}"

  defp event_ref(%Tet.Event{} = event) do
    [event.session_id || "global", type_name(event.type)]
    |> Enum.join(":")
  end

  defp format_sequence(sequence) when is_integer(sequence), do: "##{sequence}"
  defp format_sequence(_sequence), do: "#-"

  defp type_name(type) when is_atom(type), do: Atom.to_string(type)
  defp type_name(type), do: to_string(type)
end
