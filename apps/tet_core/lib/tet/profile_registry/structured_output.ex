defmodule Tet.ProfileRegistry.StructuredOutput do
  @moduledoc """
  Validates provider responses against JSON Schema defined in profile output schemas.

  Supports a subset of JSON Schema keywords for structured output validation:
  - type, properties, required, additionalProperties, items, enum
  - pattern, minimum/maximum, minLength/maxLength, minItems/maxItems
  - $ref (resolved against root schema $defs)

  Never crashes on malformed input. Returns `:ok` for valid data or
  `{:error, list_of_errors}` for invalid data.
  """

  alias Tet.ProfileRegistry.Error

  @doc """
  Validate `data` against the `:output` schema from a profile's schema overlay.

  Returns `:ok` if valid, `{:error, list_of_errors}` if invalid.

  ## Examples

      iex> Tet.ProfileRegistry.StructuredOutput.validate(%{"name" => "Alice"}, %{output: %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}}})
      :ok

      iex> Tet.ProfileRegistry.StructuredOutput.validate(42, %{output: %{"type" => "string"}})
      {:error, [%Tet.ProfileRegistry.Error{path: [], code: :invalid_type}]}
  """
  @spec validate(data :: term(), schema_overlay :: map(), opts :: keyword()) ::
          :ok | {:error, [Error.t()]}
  def validate(data, schema_overlay, _opts \\ []) do
    schema = extract_output_schema(schema_overlay)
    errors = validate_value(data, schema, schema, [])

    case errors do
      [] -> :ok
      errors -> {:error, Enum.reverse(errors)}
    end
  rescue
    _ -> {:error, [error([], :internal_error, "validation crashed unexpectedly", %{})]}
  end

  # ── Schema extraction ──────────────────────────────────────────────────────

  defp extract_output_schema(schema_overlay) when is_map(schema_overlay) do
    cond do
      Map.has_key?(schema_overlay, :output) -> Map.fetch!(schema_overlay, :output)
      Map.has_key?(schema_overlay, "output") -> Map.fetch!(schema_overlay, "output")
      true -> %{}
    end
  end

  defp extract_output_schema(_schema_overlay), do: %{}

  # ── Value validation (recursive dispatch) ──────────────────────────────────

  defp validate_value(_data, schema, _root, _path) when not is_map(schema), do: []

  defp validate_value(data, schema, root, path) do
    resolved = resolve_ref(schema, root)

    if resolved != schema do
      validate_value(data, resolved, root, path)
    else
      type_errors = check_type(data, resolved, path)
      enum_errors = check_enum(data, resolved, path)
      pattern_errors = check_pattern(data, resolved, path)
      range_errors = check_numeric_range(data, resolved, path)
      length_errors = check_string_length(data, resolved, path)
      array_len_errors = check_array_length(data, resolved, path)
      required_errors = check_required(data, resolved, path)
      props_errors = check_properties(data, resolved, root, path)
      items_errors = check_items(data, resolved, root, path)
      additional_errors = check_additional_properties(data, resolved, root, path)

      type_errors ++
        enum_errors ++
        pattern_errors ++
        range_errors ++
        length_errors ++
        array_len_errors ++
        required_errors ++
        props_errors ++ items_errors ++ additional_errors
    end
  end

  # ── $ref resolution ───────────────────────────────────────────────────────

  defp resolve_ref(schema, root) when is_map(schema) do
    if Map.has_key?(schema, "$ref") do
      ref_path = Map.fetch!(schema, "$ref")
      resolve_pointer(ref_path, root)
    else
      schema
    end
  end

  defp resolve_ref(schema, _root), do: schema

  defp resolve_pointer("#" <> path, root) when is_map(root) do
    parts = String.split(path, "/", trim: true)
    follow_pointer(root, parts)
  end

  defp resolve_pointer(_, _root), do: %{}

  defp follow_pointer(value, []), do: value

  defp follow_pointer(value, [part | rest]) when is_map(value) do
    cond do
      Map.has_key?(value, part) ->
        follow_pointer(Map.fetch!(value, part), rest)

      true ->
        resolve_atom_key(value, part, rest)
    end
  end

  defp follow_pointer(_value, _parts), do: %{}

  defp resolve_atom_key(value, part, rest) do
    try do
      key = String.to_existing_atom(part)

      if Map.has_key?(value, key) do
        follow_pointer(Map.fetch!(value, key), rest)
      else
        %{}
      end
    rescue
      ArgumentError -> %{}
    end
  end

  # ── Type check ─────────────────────────────────────────────────────────────

  defp check_type(data, schema, path) do
    case fetch_string_field(schema, "type") do
      nil ->
        []

      type ->
        if type_matches?(data, type) do
          []
        else
          [type_error(path, type, data)]
        end
    end
  end

  defp fetch_string_field(schema, field) when is_map(schema) do
    cond do
      Map.has_key?(schema, field) ->
        case Map.fetch!(schema, field) do
          value when is_binary(value) -> value
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp fetch_string_field(_schema, _field), do: nil

  defp type_matches?(_data, type) when not is_binary(type), do: false

  defp type_matches?(data, "null"), do: is_nil(data)
  defp type_matches?(data, "boolean"), do: is_boolean(data)
  defp type_matches?(data, "integer"), do: is_integer(data)
  defp type_matches?(data, "number"), do: is_number(data)
  defp type_matches?(data, "string"), do: is_binary(data)
  defp type_matches?(data, "array"), do: is_list(data)

  defp type_matches?(data, "object") do
    is_map(data) and not is_struct(data)
  end

  defp type_matches?(_data, _unknown_type), do: false

  # ── Enum check ─────────────────────────────────────────────────────────────

  defp check_enum(data, schema, path) do
    case fetch_list_field(schema, "enum") do
      nil ->
        []

      enum_vals when is_list(enum_vals) ->
        if data in enum_vals, do: [], else: [enum_error(path, data, enum_vals)]

      _ ->
        []
    end
  end

  # ── Pattern check (strings only) ───────────────────────────────────────────

  defp check_pattern(data, schema, path) when is_binary(data) do
    case fetch_pattern(schema) do
      nil ->
        []

      {:ok, regex} ->
        if Regex.match?(regex, data), do: [], else: [pattern_error(path, data, regex)]

      _ ->
        []
    end
  end

  defp check_pattern(_data, _schema, _path), do: []

  defp fetch_pattern(schema) do
    case fetch_string_field(schema, "pattern") do
      nil ->
        nil

      pattern_str when is_binary(pattern_str) ->
        try do
          {:ok, Regex.compile!(pattern_str)}
        rescue
          _ -> :invalid
        end

      _ ->
        :invalid
    end
  end

  # ── Numeric range (minimum / maximum) ──────────────────────────────────────

  defp check_numeric_range(data, schema, path) when is_number(data) do
    minimum = fetch_numeric_field(schema, "minimum")
    maximum = fetch_numeric_field(schema, "maximum")

    min_errors =
      if minimum != :none and data < minimum,
        do: [range_error(path, data, :minimum, minimum)],
        else: []

    max_errors =
      if maximum != :none and data > maximum,
        do: [range_error(path, data, :maximum, maximum)],
        else: []

    min_errors ++ max_errors
  end

  defp check_numeric_range(_data, _schema, _path), do: []

  defp fetch_numeric_field(schema, field) when is_map(schema) do
    cond do
      Map.has_key?(schema, field) ->
        case Map.fetch!(schema, field) do
          value when is_number(value) -> value
          _ -> :none
        end

      true ->
        :none
    end
  end

  defp fetch_numeric_field(_schema, _field), do: :none

  # ── String length (minLength / maxLength) ──────────────────────────────────

  defp check_string_length(data, schema, path) when is_binary(data) do
    min_len = fetch_integer_field(schema, "minLength")
    max_len = fetch_integer_field(schema, "maxLength")
    len = String.length(data)

    min_errors =
      if min_len != :none and len < min_len,
        do: [length_error(path, data, :minLength, min_len)],
        else: []

    max_errors =
      if max_len != :none and len > max_len,
        do: [length_error(path, data, :maxLength, max_len)],
        else: []

    min_errors ++ max_errors
  end

  defp check_string_length(_data, _schema, _path), do: []

  # ── Array length (minItems / maxItems) ─────────────────────────────────────

  defp check_array_length(data, schema, path) when is_list(data) do
    min_items = fetch_integer_field(schema, "minItems")
    max_items = fetch_integer_field(schema, "maxItems")
    len = length(data)

    min_errors =
      if min_items != :none and len < min_items,
        do: [length_error(path, data, :minItems, min_items)],
        else: []

    max_errors =
      if max_items != :none and len > max_items,
        do: [length_error(path, data, :maxItems, max_items)],
        else: []

    min_errors ++ max_errors
  end

  defp check_array_length(_data, _schema, _path), do: []

  defp fetch_integer_field(schema, field) when is_map(schema) do
    cond do
      Map.has_key?(schema, field) ->
        case Map.fetch!(schema, field) do
          value when is_integer(value) -> value
          _ -> :none
        end

      true ->
        :none
    end
  end

  defp fetch_integer_field(_schema, _field), do: :none

  # ── Required fields (object only) ──────────────────────────────────────────

  defp check_required(data, schema, path) when is_map(data) and not is_struct(data) do
    case fetch_list_field(schema, "required") do
      nil ->
        []

      required_fields when is_list(required_fields) ->
        required_fields
        |> Enum.reduce([], fn field, errors ->
          if Map.has_key?(data, field) do
            errors
          else
            [required_missing_error(path ++ [to_string(field)], field) | errors]
          end
        end)
        |> Enum.reverse()

      _ ->
        []
    end
  end

  defp check_required(_data, _schema, _path), do: []

  # ── Properties (object) ────────────────────────────────────────────────────

  defp check_properties(data, schema, root, path) when is_map(data) and not is_struct(data) do
    case fetch_map_field(schema, "properties") do
      nil ->
        []

      properties ->
        Enum.reduce(properties, [], fn {prop_name, prop_schema}, errors ->
          prop_key = to_string(prop_name)

          if Map.has_key?(data, prop_key) do
            prop_value = Map.fetch!(data, prop_key)
            errors ++ validate_value(prop_value, prop_schema, root, path ++ [prop_key])
          else
            errors
          end
        end)
    end
  end

  defp check_properties(_data, _schema, _root, _path), do: []

  # ── Items (array) ──────────────────────────────────────────────────────────

  defp check_items(data, schema, root, path) when is_list(data) do
    case fetch_map_field(schema, "items") do
      nil ->
        []

      items_schema ->
        data
        |> Enum.with_index()
        |> Enum.reduce([], fn {item, idx}, errors ->
          errors ++ validate_value(item, items_schema, root, path ++ [idx])
        end)
    end
  end

  defp check_items(_data, _schema, _root, _path), do: []

  # ── additionalProperties (object) ──────────────────────────────────────────

  defp check_additional_properties(data, schema, root, path)
       when is_map(data) and not is_struct(data) do
    case fetch_additional_properties_config(schema) do
      :not_present ->
        []

      {false, _} ->
        disallowed = extra_keys(data, schema)

        Enum.map(disallowed, fn key ->
          extra_property_error(path ++ [key], key)
        end)

      {:schema, additional_schema} ->
        extra = extra_keys(data, schema)

        Enum.reduce(extra, [], fn key, errors ->
          value = Map.fetch!(data, key)
          errors ++ validate_value(value, additional_schema, root, path ++ [key])
        end)
    end
  end

  defp check_additional_properties(_data, _schema, _root, _path), do: []

  defp fetch_additional_properties_config(schema) when is_map(schema) do
    cond do
      not Map.has_key?(schema, "additionalProperties") and
          not Map.has_key?(schema, :additionalProperties) ->
        :not_present

      Map.has_key?(schema, "additionalProperties") ->
        case Map.fetch!(schema, "additionalProperties") do
          false -> {false, false}
          true -> :not_present
          schema_val when is_map(schema_val) -> {:schema, schema_val}
          _ -> :not_present
        end

      Map.has_key?(schema, :additionalProperties) ->
        case Map.fetch!(schema, :additionalProperties) do
          false -> {false, false}
          true -> :not_present
          schema_val when is_map(schema_val) -> {:schema, schema_val}
          _ -> :not_present
        end
    end
  end

  defp fetch_additional_properties_config(_schema), do: :not_present

  defp extra_keys(data, schema) do
    defined = property_names(schema) |> MapSet.new()
    actual = Map.keys(data) |> MapSet.new()
    MapSet.difference(actual, defined) |> MapSet.to_list() |> Enum.sort()
  end

  defp property_names(schema) when is_map(schema) do
    cond do
      Map.has_key?(schema, "properties") ->
        case Map.fetch!(schema, "properties") do
          props when is_map(props) -> Map.keys(props)
          _ -> []
        end

      Map.has_key?(schema, :properties) ->
        case Map.fetch!(schema, :properties) do
          props when is_map(props) -> Map.keys(props)
          _ -> []
        end

      true ->
        []
    end
  end

  defp property_names(_schema), do: []

  # ── Generic field fetch helpers ────────────────────────────────────────────

  defp fetch_list_field(schema, field) when is_map(schema) do
    cond do
      Map.has_key?(schema, field) ->
        case Map.fetch!(schema, field) do
          value when is_list(value) -> value
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp fetch_list_field(_schema, _field), do: nil

  defp fetch_map_field(schema, field) when is_map(schema) do
    cond do
      Map.has_key?(schema, field) ->
        case Map.fetch!(schema, field) do
          value when is_map(value) -> value
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp fetch_map_field(_schema, _field), do: nil

  # ── Error construction ─────────────────────────────────────────────────────

  defp type_error(path, expected, actual) do
    error(path, :invalid_type, "#{path_label(path)} must be #{expected}", %{
      expected: expected,
      actual: actual_type(actual)
    })
  end

  defp enum_error(path, value, allowed) do
    error(path, :invalid_value, "#{path_label(path)} is not in enum", %{
      value: value,
      allowed: allowed
    })
  end

  defp pattern_error(path, value, regex) do
    error(path, :invalid_value, "#{path_label(path)} does not match pattern", %{
      value: value,
      pattern: inspect(regex)
    })
  end

  defp range_error(path, value, constraint, limit) do
    error(path, :invalid_value, "#{path_label(path)} violates #{constraint} constraint", %{
      value: value,
      constraint: constraint,
      limit: limit
    })
  end

  defp length_error(path, value, constraint, limit) do
    error(path, :invalid_value, "#{path_label(path)} violates #{constraint} constraint", %{
      value: value,
      constraint: constraint,
      limit: limit
    })
  end

  defp required_missing_error(path, field) do
    error(path, :required, "#{path_label(path)} is required", %{field: field})
  end

  defp extra_property_error(path, key) do
    error(path, :invalid_value, "#{path_label(path)} is an unexpected property", %{key: key})
  end

  defp error(path, code, message, details) do
    %Error{path: path, code: code, message: message, details: details}
  end

  defp path_label([]), do: "root"

  defp path_label(path) do
    Enum.map_join(path, ".", &to_string/1)
  end

  defp actual_type(value) when is_map(value), do: "object"
  defp actual_type(value) when is_list(value), do: "array"
  defp actual_type(value) when is_binary(value), do: "string"
  defp actual_type(value) when is_boolean(value), do: "boolean"
  defp actual_type(value) when is_nil(value), do: "null"
  defp actual_type(value) when is_integer(value), do: "integer"
  defp actual_type(value) when is_float(value), do: "number"
  defp actual_type(value) when is_atom(value), do: "atom"
  defp actual_type(_value), do: "term"
end
