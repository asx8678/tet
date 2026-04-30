defmodule Tet.ModelRegistry.Validator do
  @moduledoc false

  alias Tet.ModelRegistry.Error

  def validate(raw) when is_map(raw) do
    {schema_version, errors} =
      required_positive_integer_field(raw, "schema_version", ["schema_version"], [])

    {providers_raw, errors} =
      required_non_empty_map_field(raw, "providers", ["providers"], errors)

    {models_raw, errors} = required_non_empty_map_field(raw, "models", ["models"], errors)

    {profile_pins_raw, errors} =
      required_non_empty_map_field(raw, "profile_pins", ["profile_pins"], errors)

    providers_raw = providers_raw || %{}
    models_raw = models_raw || %{}
    profile_pins_raw = profile_pins_raw || %{}
    provider_ids = declared_ids(providers_raw)
    model_ids = declared_ids(models_raw)

    {providers, errors} =
      validate_entries(providers_raw, ["providers"], errors, &validate_provider/3)

    {models, errors} =
      validate_entries(models_raw, ["models"], errors, fn id, value, entry_errors ->
        validate_model(id, value, provider_ids, entry_errors)
      end)

    {profile_pins, errors} =
      validate_entries(profile_pins_raw, ["profile_pins"], errors, fn id, value, entry_errors ->
        validate_profile_pin(id, value, model_ids, entry_errors)
      end)

    if errors == [] do
      {:ok,
       %{
         schema_version: schema_version,
         providers: providers,
         models: models,
         profile_pins: profile_pins
       }}
    else
      {:error, Enum.reverse(errors)}
    end
  end

  def validate(raw) do
    {:error, [type_error([], "object", raw, "model registry must be a JSON object")]}
  end

  defp validate_provider(id, raw, errors) when is_map(raw) do
    path = ["providers", id]
    {type, errors} = required_string_field(raw, "type", path ++ ["type"], errors)

    {display_name, errors} =
      optional_string_field(raw, "display_name", id, path ++ ["display_name"], errors)

    {config, errors} = optional_map_field(raw, "config", %{}, path ++ ["config"], errors)

    {%{id: id, type: type, display_name: display_name, config: config}, errors}
  end

  defp validate_provider(id, raw, errors) do
    path = ["providers", id]

    {nil,
     [
       type_error(path, "object", raw, "provider entry must be an object")
       | errors
     ]}
  end

  defp validate_model(id, raw, provider_ids, errors) when is_map(raw) do
    path = ["models", id]

    {provider, errors} =
      required_reference_field(raw, "provider", provider_ids, path ++ ["provider"], errors)

    {model, errors} = required_string_field(raw, "model", path ++ ["model"], errors)

    {display_name, errors} =
      optional_string_field(raw, "display_name", id, path ++ ["display_name"], errors)

    {config, errors} = optional_map_field(raw, "config", %{}, path ++ ["config"], errors)
    {capabilities, errors} = validate_capabilities(raw, path, errors)

    {%{
       id: id,
       provider: provider,
       model: model,
       display_name: display_name,
       capabilities: capabilities,
       config: config
     }, errors}
  end

  defp validate_model(id, raw, _provider_ids, errors) do
    path = ["models", id]

    {nil,
     [
       type_error(path, "object", raw, "model entry must be an object")
       | errors
     ]}
  end

  defp validate_profile_pin(id, raw, model_ids, errors) when is_map(raw) do
    path = ["profile_pins", id]

    {default_model, errors} =
      required_reference_field(raw, "default_model", model_ids, path ++ ["default_model"], errors)

    {fallback_models, errors} =
      optional_reference_list_field(
        raw,
        "fallback_models",
        model_ids,
        [],
        path ++ ["fallback_models"],
        errors
      )

    {%{profile: id, default_model: default_model, fallback_models: fallback_models}, errors}
  end

  defp validate_profile_pin(id, raw, _model_ids, errors) do
    path = ["profile_pins", id]

    {nil,
     [
       type_error(path, "object", raw, "profile pin entry must be an object")
       | errors
     ]}
  end

  defp validate_capabilities(raw, model_path, errors) do
    path = model_path ++ ["capabilities"]

    case required_map_field(raw, "capabilities", path, errors) do
      {nil, errors} ->
        {%{}, errors}

      {capabilities, errors} ->
        {context_raw, errors} =
          required_map_field(capabilities, "context", path ++ ["context"], errors)

        {cache_raw, errors} = required_map_field(capabilities, "cache", path ++ ["cache"], errors)

        {tool_calls_raw, errors} =
          required_map_field(capabilities, "tool_calls", path ++ ["tool_calls"], errors)

        {context, errors} = validate_context_capability(context_raw, path ++ ["context"], errors)
        {cache, errors} = validate_cache_capability(cache_raw, path ++ ["cache"], errors)

        {tool_calls, errors} =
          validate_tool_call_capability(tool_calls_raw, path ++ ["tool_calls"], errors)

        {%{context: context, cache: cache, tool_calls: tool_calls}, errors}
    end
  end

  defp validate_context_capability(nil, _path, errors), do: {%{}, errors}

  defp validate_context_capability(raw, path, errors) do
    {window_tokens, errors} =
      required_positive_integer_field(raw, "window_tokens", path ++ ["window_tokens"], errors)

    {max_output_tokens, errors} =
      optional_positive_integer_field(
        raw,
        "max_output_tokens",
        path ++ ["max_output_tokens"],
        errors
      )

    errors = validate_max_output(window_tokens, max_output_tokens, path, errors)

    context =
      %{window_tokens: window_tokens}
      |> put_optional(:max_output_tokens, max_output_tokens)

    {context, errors}
  end

  defp validate_cache_capability(nil, _path, errors), do: {%{}, errors}

  defp validate_cache_capability(raw, path, errors) do
    {supported, errors} = required_boolean_field(raw, "supported", path ++ ["supported"], errors)

    optional_boolean_fields(
      raw,
      ["prompt", "read", "write"],
      %{supported: supported},
      path,
      errors
    )
  end

  defp validate_tool_call_capability(nil, _path, errors), do: {%{}, errors}

  defp validate_tool_call_capability(raw, path, errors) do
    {supported, errors} = required_boolean_field(raw, "supported", path ++ ["supported"], errors)

    {parallel, errors} =
      optional_boolean_field(raw, "parallel", false, path ++ ["parallel"], errors)

    {%{supported: supported, parallel: parallel}, errors}
  end

  defp validate_max_output(window_tokens, max_output_tokens, path, errors)
       when is_integer(window_tokens) and is_integer(max_output_tokens) and
              max_output_tokens > window_tokens do
    [
      error(
        path ++ ["max_output_tokens"],
        :invalid_value,
        "max_output_tokens must not exceed window_tokens",
        %{
          max_output_tokens: max_output_tokens,
          window_tokens: window_tokens
        }
      )
      | errors
    ]
  end

  defp validate_max_output(_window_tokens, _max_output_tokens, _path, errors), do: errors

  defp validate_entries(raw, path, errors, validator) do
    Enum.reduce(raw, {%{}, errors}, fn {key, value}, {entries, entry_errors} ->
      case id_from_key(key) do
        {:ok, id} ->
          if Map.has_key?(entries, id) do
            duplicate =
              error(path ++ [id], :duplicate_id, "duplicate registry id #{inspect(id)}", %{})

            {entries, [duplicate | entry_errors]}
          else
            {entry, entry_errors} = validator.(id, value, entry_errors)
            {put_entry(entries, id, entry), entry_errors}
          end

        {:error, message} ->
          invalid = error(path ++ [inspect(key)], :invalid_id, message, %{key: inspect(key)})
          {entries, [invalid | entry_errors]}
      end
    end)
  end

  defp put_entry(entries, _id, nil), do: entries
  defp put_entry(entries, id, entry), do: Map.put(entries, id, entry)

  defp declared_ids(raw) when is_map(raw) do
    raw
    |> Map.keys()
    |> Enum.reduce(MapSet.new(), fn key, ids ->
      case id_from_key(key) do
        {:ok, id} -> MapSet.put(ids, id)
        {:error, _message} -> ids
      end
    end)
  end

  defp declared_ids(_raw), do: MapSet.new()

  defp required_reference_field(raw, field, allowed_ids, path, errors) do
    case required_string_field(raw, field, path, errors) do
      {nil, errors} ->
        {nil, errors}

      {value, errors} ->
        if MapSet.member?(allowed_ids, value) do
          {value, errors}
        else
          {value,
           [
             error(
               path,
               :unknown_reference,
               "#{path_label(path)} references unknown id #{inspect(value)}",
               %{
                 reference: value,
                 allowed: Enum.sort(MapSet.to_list(allowed_ids))
               }
             )
             | errors
           ]}
        end
    end
  end

  defp optional_reference_list_field(raw, field, allowed_ids, default, path, errors) do
    case fetch_field(raw, field) do
      :error ->
        {default, errors}

      {:ok, value} when is_list(value) ->
        value
        |> Enum.with_index()
        |> Enum.reduce({[], errors}, fn {item, index}, {items, item_errors} ->
          item_path = path ++ [index]

          case string_value(item) do
            {:ok, id} ->
              item_errors =
                if MapSet.member?(allowed_ids, id) do
                  item_errors
                else
                  [
                    error(
                      item_path,
                      :unknown_reference,
                      "#{path_label(item_path)} references unknown id #{inspect(id)}",
                      %{
                        reference: id,
                        allowed: Enum.sort(MapSet.to_list(allowed_ids))
                      }
                    )
                    | item_errors
                  ]
                end

              {[id | items], item_errors}

            :error ->
              {[item | items], [type_error(item_path, "string", item) | item_errors]}
          end
        end)
        |> then(fn {items, item_errors} -> {Enum.reverse(items), item_errors} end)

      {:ok, value} ->
        {default, [type_error(path, "array", value) | errors]}
    end
  end

  defp required_non_empty_map_field(raw, field, path, errors) do
    case required_map_field(raw, field, path, errors) do
      {nil, errors} ->
        {nil, errors}

      {value, errors} when map_size(value) == 0 ->
        {value,
         [
           error(path, :invalid_value, "#{path_label(path)} must declare at least one entry", %{})
           | errors
         ]}

      {value, errors} ->
        {value, errors}
    end
  end

  defp required_map_field(raw, field, path, errors) do
    case fetch_field(raw, field) do
      :error -> {nil, [required_error(path) | errors]}
      {:ok, value} when is_map(value) -> {value, errors}
      {:ok, value} -> {nil, [type_error(path, "object", value) | errors]}
    end
  end

  defp optional_map_field(raw, field, default, path, errors) do
    case fetch_field(raw, field) do
      :error -> {default, errors}
      {:ok, value} when is_map(value) -> {value, errors}
      {:ok, value} -> {default, [type_error(path, "object", value) | errors]}
    end
  end

  defp required_string_field(raw, field, path, errors) do
    case fetch_field(raw, field) do
      :error -> {nil, [required_error(path) | errors]}
      {:ok, value} -> string_field_value(value, path, errors)
    end
  end

  defp optional_string_field(raw, field, default, path, errors) do
    case fetch_field(raw, field) do
      :error -> {default, errors}
      {:ok, value} -> string_field_value(value, path, errors, default)
    end
  end

  defp string_field_value(value, path, errors, fallback \\ nil) do
    case string_value(value) do
      {:ok, string} -> {string, errors}
      :error -> {fallback, [type_error(path, "non-empty string", value) | errors]}
    end
  end

  defp required_positive_integer_field(raw, field, path, errors) do
    case fetch_field(raw, field) do
      :error -> {nil, [required_error(path) | errors]}
      {:ok, value} when is_integer(value) and value > 0 -> {value, errors}
      {:ok, value} -> {value, [type_error(path, "positive integer", value) | errors]}
    end
  end

  defp optional_positive_integer_field(raw, field, path, errors) do
    case fetch_field(raw, field) do
      :error -> {nil, errors}
      {:ok, value} when is_integer(value) and value > 0 -> {value, errors}
      {:ok, value} -> {value, [type_error(path, "positive integer", value) | errors]}
    end
  end

  defp required_boolean_field(raw, field, path, errors) do
    case fetch_field(raw, field) do
      :error -> {nil, [required_error(path) | errors]}
      {:ok, value} when is_boolean(value) -> {value, errors}
      {:ok, value} -> {value, [type_error(path, "boolean", value) | errors]}
    end
  end

  defp optional_boolean_field(raw, field, default, path, errors) do
    case fetch_field(raw, field) do
      :error -> {default, errors}
      {:ok, value} when is_boolean(value) -> {value, errors}
      {:ok, value} -> {default, [type_error(path, "boolean", value) | errors]}
    end
  end

  defp optional_boolean_fields(raw, fields, acc, path, errors) do
    Enum.reduce(fields, {acc, errors}, fn field, {capability, field_errors} ->
      {value, field_errors} =
        optional_boolean_field(raw, field, nil, path ++ [field], field_errors)

      if is_nil(value) do
        {capability, field_errors}
      else
        {Map.put(capability, String.to_atom(field), value), field_errors}
      end
    end)
  end

  defp fetch_field(raw, field) do
    atom_field = String.to_atom(field)

    cond do
      Map.has_key?(raw, field) -> {:ok, Map.fetch!(raw, field)}
      Map.has_key?(raw, atom_field) -> {:ok, Map.fetch!(raw, atom_field)}
      true -> :error
    end
  end

  defp id_from_key(key) when is_binary(key), do: normalize_id(key)
  defp id_from_key(key) when is_atom(key), do: key |> Atom.to_string() |> normalize_id()
  defp id_from_key(_key), do: {:error, "registry ids must be strings or atoms"}

  defp normalize_id(value) do
    case String.trim(value) do
      "" -> {:error, "registry ids must not be blank"}
      id -> {:ok, id}
    end
  end

  defp string_value(value) when is_binary(value), do: normalize_id(value)
  defp string_value(value) when is_boolean(value) or is_nil(value), do: :error
  defp string_value(value) when is_atom(value), do: value |> Atom.to_string() |> normalize_id()
  defp string_value(_value), do: :error

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp required_error(path) do
    error(path, :required, "#{path_label(path)} is required", %{})
  end

  defp type_error(path, expected, actual, message \\ nil) do
    error(path, :invalid_type, message || "#{path_label(path)} must be #{expected}", %{
      expected: expected,
      actual: actual_type(actual)
    })
  end

  defp error(path, code, message, details) do
    %Error{path: path, code: code, message: message, details: details}
  end

  defp actual_type(value) when is_map(value), do: "object"
  defp actual_type(value) when is_list(value), do: "array"
  defp actual_type(value) when is_binary(value), do: "string"
  defp actual_type(value) when is_boolean(value), do: "boolean"
  defp actual_type(value) when is_nil(value), do: "null"
  defp actual_type(value) when is_integer(value), do: "integer"
  defp actual_type(value) when is_float(value), do: "float"
  defp actual_type(value) when is_atom(value), do: "atom"
  defp actual_type(_value), do: "term"

  defp path_label([]), do: "registry"

  defp path_label(path) do
    Enum.map_join(path, ".", &to_string/1)
  end
end
