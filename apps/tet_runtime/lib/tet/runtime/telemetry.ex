defmodule Tet.Runtime.Telemetry do
  @moduledoc """
  Small runtime telemetry facade.

  The standalone closure intentionally does not require telemetry exporters or web
  servers. If `:telemetry` is present, events are forwarded. Tests and callers can
  also pass `:telemetry_emit` in opts to capture events without pulling a dep.
  """

  @doc "Emits a telemetry event through an injected callback and optional :telemetry."
  def execute(event_name, measurements \\ %{}, metadata \\ %{}, opts \\ [])
      when is_list(event_name) and is_map(measurements) and is_map(metadata) and is_list(opts) do
    safe_measurements = numeric_measurements(measurements)
    safe_metadata = metadata |> Tet.Redactor.redact() |> json_friendly()

    emit_injected(event_name, safe_measurements, safe_metadata, opts)
    emit_telemetry(event_name, safe_measurements, safe_metadata)

    :ok
  end

  defp emit_injected(event_name, measurements, metadata, opts) do
    case Keyword.get(opts, :telemetry_emit) do
      emit when is_function(emit, 3) ->
        emit.(event_name, measurements, metadata)

      emit when is_function(emit, 1) ->
        emit.(%{event: event_name, measurements: measurements, metadata: metadata})

      _other ->
        :ok
    end
  catch
    _kind, _reason -> :ok
  end

  defp emit_telemetry(event_name, measurements, metadata) do
    if Code.ensure_loaded?(:telemetry) and function_exported?(:telemetry, :execute, 3) do
      apply(:telemetry, :execute, [event_name, measurements, metadata])
    end
  catch
    _kind, _reason -> :ok
  end

  defp numeric_measurements(measurements) do
    measurements
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.filter(fn {_key, value} -> is_number(value) end)
    |> Map.new()
  end

  defp json_friendly(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {json_key(key), json_friendly(nested)} end)
  end

  defp json_friendly(value) when is_list(value), do: Enum.map(value, &json_friendly/1)
  defp json_friendly(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_friendly()
  defp json_friendly(value) when value in [nil, true, false], do: value
  defp json_friendly(value) when is_atom(value), do: Atom.to_string(value)
  defp json_friendly(value), do: value

  defp json_key(key) when is_atom(key), do: key
  defp json_key(key), do: key
end
