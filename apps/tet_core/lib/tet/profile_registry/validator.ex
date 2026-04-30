defmodule Tet.ProfileRegistry.Validator do
  @moduledoc false

  import Tet.ProfileRegistry.Validator.Fields

  @overlay_kinds [:prompt, :tool, :model, :task, :schema, :cache]
  @cache_policies ["preserve", "drop", "replace"]
  @schema_fields [:input, :output, :response, :artifact, :tool_call]

  def validate(raw, opts \\ [])

  def validate(raw, opts) when is_map(raw) and is_list(opts) do
    model_refs = model_reference_index(Keyword.get(opts, :model_registry))

    {schema_version, errors} =
      required_positive_integer_field(raw, "schema_version", ["schema_version"], [])

    {profiles_raw, errors} =
      required_non_empty_map_field(raw, "profiles", ["profiles"], errors)

    profiles_raw = profiles_raw || %{}

    {profiles, errors} =
      validate_entries(profiles_raw, ["profiles"], errors, fn id, value, entry_errors ->
        validate_profile(id, value, model_refs, entry_errors)
      end)

    if errors == [] do
      {:ok, %{schema_version: schema_version, profiles: profiles}}
    else
      {:error, Enum.reverse(errors)}
    end
  end

  def validate(raw, _opts) do
    {:error, [type_error([], "object", raw, "profile registry must be a JSON object")]}
  end

  defp validate_profile(id, raw, model_refs, errors) when is_map(raw) do
    path = ["profiles", id]

    {display_name, errors} =
      optional_string_field(raw, "display_name", id, path ++ ["display_name"], errors)

    {description, errors} =
      optional_string_field(raw, "description", "", path ++ ["description"], errors)

    {version, errors} = optional_string_field(raw, "version", "1", path ++ ["version"], errors)
    {tags, errors} = optional_string_list_field(raw, "tags", [], path ++ ["tags"], errors)
    {metadata, errors} = optional_map_field(raw, "metadata", %{}, path ++ ["metadata"], errors)
    {overlays, errors} = validate_overlays(raw, id, model_refs, path, errors)

    {%{
       id: id,
       display_name: display_name,
       description: description,
       version: version,
       tags: tags,
       overlays: overlays,
       metadata: metadata
     }, errors}
  end

  defp validate_profile(id, raw, _model_refs, errors) do
    path = ["profiles", id]
    {nil, [type_error(path, "object", raw, "profile descriptor must be an object") | errors]}
  end

  defp validate_overlays(raw, profile_id, model_refs, profile_path, errors) do
    path = profile_path ++ ["overlays"]

    case required_map_field(raw, "overlays", path, errors) do
      {nil, errors} ->
        {default_overlays(), errors}

      {overlays_raw, errors} ->
        errors = validate_known_overlay_keys(overlays_raw, path, errors)

        Enum.reduce(@overlay_kinds, {%{}, errors}, fn kind, {overlays, overlay_errors} ->
          field = Atom.to_string(kind)
          overlay_path = path ++ [field]

          case required_map_field(overlays_raw, field, overlay_path, overlay_errors) do
            {nil, overlay_errors} ->
              {Map.put(overlays, kind, default_overlay(kind)), overlay_errors}

            {overlay_raw, overlay_errors} ->
              {overlay, overlay_errors} =
                validate_overlay(
                  kind,
                  overlay_raw,
                  profile_id,
                  model_refs,
                  overlay_path,
                  overlay_errors
                )

              {Map.put(overlays, kind, overlay), overlay_errors}
          end
        end)
    end
  end

  defp validate_overlay(:prompt, raw, _profile_id, _model_refs, path, errors) do
    {system, errors} = optional_string_field(raw, "system", nil, path ++ ["system"], errors)
    {layers, errors} = optional_prompt_layers(raw, path ++ ["layers"], errors)
    {metadata, errors} = optional_map_field(raw, "metadata", %{}, path ++ ["metadata"], errors)

    {%{layers: layers, metadata: metadata} |> put_optional(:system, system), errors}
  end

  defp validate_overlay(:tool, raw, _profile_id, _model_refs, path, errors) do
    {allow, errors} = optional_string_list_field(raw, "allow", [], path ++ ["allow"], errors)
    {deny, errors} = optional_string_list_field(raw, "deny", [], path ++ ["deny"], errors)
    {mode, errors} = optional_string_field(raw, "mode", "inherit", path ++ ["mode"], errors)
    {metadata, errors} = optional_map_field(raw, "metadata", %{}, path ++ ["metadata"], errors)
    errors = validate_disjoint_lists(allow, deny, path, errors)

    {%{allow: allow, deny: deny, mode: mode, metadata: metadata}, errors}
  end

  defp validate_overlay(:model, raw, profile_id, model_refs, path, errors) do
    {default_model, errors} =
      optional_model_reference_field(
        raw,
        "default_model",
        model_refs,
        path ++ ["default_model"],
        errors
      )

    {fallback_models, errors} =
      optional_model_reference_list_field(
        raw,
        "fallback_models",
        model_refs,
        [],
        path ++ ["fallback_models"],
        errors
      )

    {profile_pin, errors} =
      optional_profile_pin_reference_field(
        raw,
        "profile_pin",
        model_refs,
        path ++ ["profile_pin"],
        errors
      )

    {settings, errors} = optional_map_field(raw, "settings", %{}, path ++ ["settings"], errors)
    errors = require_model_selection(default_model, profile_pin, profile_id, path, errors)

    {%{fallback_models: fallback_models, settings: settings}
     |> put_optional(:default_model, default_model)
     |> put_optional(:profile_pin, profile_pin), errors}
  end

  defp validate_overlay(:task, raw, _profile_id, _model_refs, path, errors) do
    {categories, errors} =
      optional_string_list_field(raw, "categories", [], path ++ ["categories"], errors)

    {modes, errors} = optional_string_list_field(raw, "modes", [], path ++ ["modes"], errors)

    {default_mode, errors} =
      optional_string_field(raw, "default_mode", nil, path ++ ["default_mode"], errors)

    {priority, errors} = optional_string_field(raw, "priority", nil, path ++ ["priority"], errors)
    {metadata, errors} = optional_map_field(raw, "metadata", %{}, path ++ ["metadata"], errors)
    errors = validate_default_mode(default_mode, modes, path ++ ["default_mode"], errors)

    {%{categories: categories, modes: modes, metadata: metadata}
     |> put_optional(:default_mode, default_mode)
     |> put_optional(:priority, priority), errors}
  end

  defp validate_overlay(:schema, raw, _profile_id, _model_refs, path, errors) do
    {schema_fields, errors} =
      Enum.reduce(@schema_fields, {%{}, errors}, fn field, {schema, field_errors} ->
        field_name = Atom.to_string(field)

        case optional_map_field(raw, field_name, nil, path ++ [field_name], field_errors) do
          {nil, field_errors} -> {schema, field_errors}
          {value, field_errors} -> {Map.put(schema, field, value), field_errors}
        end
      end)

    {metadata, errors} = optional_map_field(raw, "metadata", %{}, path ++ ["metadata"], errors)
    {Map.put(schema_fields, :metadata, metadata), errors}
  end

  defp validate_overlay(:cache, raw, _profile_id, _model_refs, path, errors) do
    {policy, errors} =
      optional_string_field(raw, "policy", "preserve", path ++ ["policy"], errors)

    errors = validate_cache_policy(policy, path ++ ["policy"], errors)
    {prompt, errors} = optional_boolean_field(raw, "prompt", nil, path ++ ["prompt"], errors)
    {tools, errors} = optional_boolean_field(raw, "tools", nil, path ++ ["tools"], errors)

    {ttl_seconds, errors} =
      optional_positive_integer_field(raw, "ttl_seconds", path ++ ["ttl_seconds"], errors)

    {metadata, errors} = optional_map_field(raw, "metadata", %{}, path ++ ["metadata"], errors)

    {%{policy: policy, metadata: metadata}
     |> put_optional(:prompt, prompt)
     |> put_optional(:tools, tools)
     |> put_optional(:ttl_seconds, ttl_seconds), errors}
  end

  defp optional_prompt_layers(raw, path, errors) do
    case fetch_field(raw, "layers") do
      :error ->
        {[], errors}

      {:ok, value} when is_list(value) ->
        {layers, errors} =
          value
          |> Enum.with_index()
          |> Enum.reduce({[], errors}, fn {item, index}, {items, item_errors} ->
            {layer, item_errors} = validate_prompt_layer(item, path ++ [index], item_errors)
            {[layer | items], item_errors}
          end)

        layers = Enum.reverse(Enum.reject(layers, &is_nil/1))
        {layers, validate_unique_list(layers, :id, path, errors)}

      {:ok, value} ->
        {[], [type_error(path, "array", value) | errors]}
    end
  end

  defp validate_prompt_layer(raw, path, errors) when is_map(raw) do
    {id, errors} = required_string_field(raw, "id", path ++ ["id"], errors)
    {content, errors} = required_string_field(raw, "content", path ++ ["content"], errors)
    {label, errors} = optional_string_field(raw, "label", nil, path ++ ["label"], errors)
    {metadata, errors} = optional_map_field(raw, "metadata", %{}, path ++ ["metadata"], errors)

    {%{id: id, content: content, metadata: metadata} |> put_optional(:label, label), errors}
  end

  defp validate_prompt_layer(raw, path, errors) do
    {nil, [type_error(path, "object", raw, "prompt layer must be an object") | errors]}
  end

  defp validate_entries(raw, path, errors, validator) do
    Enum.reduce(raw, {%{}, errors}, fn {key, value}, {entries, entry_errors} ->
      case id_from_key(key) do
        {:ok, id} ->
          if Map.has_key?(entries, id) do
            duplicate =
              error(path ++ [id], :duplicate_id, "duplicate profile id #{inspect(id)}", %{})

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

  defp model_reference_index(nil), do: nil

  defp model_reference_index(%{models: models, profile_pins: pins})
       when is_map(models) and is_map(pins) do
    %{models: MapSet.new(Map.keys(models)), profile_pins: MapSet.new(Map.keys(pins))}
  end

  defp model_reference_index(_registry), do: nil

  defp optional_model_reference_field(raw, field, refs, path, errors) do
    optional_reference_field(raw, field, refs, :models, "model", path, errors)
  end

  defp optional_model_reference_list_field(raw, field, refs, default, path, errors) do
    case fetch_field(raw, field) do
      :error ->
        {default, errors}

      {:ok, value} when is_list(value) ->
        {items, errors} =
          value
          |> Enum.with_index()
          |> Enum.reduce({[], errors}, fn {item, index}, {items, item_errors} ->
            item_path = path ++ [index]

            case string_value(item) do
              {:ok, id} ->
                item_errors = validate_model_reference(id, refs, item_path, item_errors)
                {[id | items], item_errors}

              :error ->
                {items, [type_error(item_path, "string", item) | item_errors]}
            end
          end)

        items = Enum.reverse(items)
        {items, validate_unique_values(items, path, errors)}

      {:ok, value} ->
        {default, [type_error(path, "array", value) | errors]}
    end
  end

  defp optional_profile_pin_reference_field(raw, field, refs, path, errors) do
    optional_reference_field(raw, field, refs, :profile_pins, "model profile pin", path, errors)
  end

  defp optional_reference_field(raw, field, refs, key, label, path, errors) do
    case optional_string_field(raw, field, nil, path, errors) do
      {nil, errors} -> {nil, errors}
      {value, errors} -> {value, validate_reference(value, refs, key, label, path, errors)}
    end
  end

  defp validate_model_reference(value, refs, path, errors) do
    validate_reference(value, refs, :models, "model", path, errors)
  end

  defp validate_reference(_value, nil, _key, _label, _path, errors), do: errors

  defp validate_reference(value, refs, key, label, path, errors) do
    allowed = Map.fetch!(refs, key)

    if MapSet.member?(allowed, value),
      do: errors,
      else: [unknown_reference(path, value, label, allowed) | errors]
  end

  defp require_model_selection(nil, nil, profile_id, path, errors) do
    message = "profiles.#{profile_id}.overlays.model must declare default_model or profile_pin"
    [error(path, :required, message, %{}) | errors]
  end

  defp require_model_selection(_default_model, _profile_pin, _profile_id, _path, errors),
    do: errors

  defp validate_known_overlay_keys(raw, path, errors) do
    Enum.reduce(raw, errors, fn {key, _value}, acc ->
      case overlay_kind_from_key(key) do
        {:ok, _kind} ->
          acc

        :error ->
          details = %{allowed: Enum.map(@overlay_kinds, &Atom.to_string/1)}

          [
            error(
              path ++ [inspect(key)],
              :unknown_overlay,
              "unknown overlay kind #{inspect(key)}",
              details
            )
            | acc
          ]
      end
    end)
  end

  defp overlay_kind_from_key(key) when is_atom(key) and key in @overlay_kinds, do: {:ok, key}

  defp overlay_kind_from_key(key) when is_binary(key) do
    normalized = key |> String.trim() |> String.downcase() |> String.replace("-", "_")

    cond do
      normalized == "tools" -> {:ok, :tool}
      true -> Enum.find_value(@overlay_kinds, :error, &overlay_kind_match?(&1, normalized))
    end
  end

  defp overlay_kind_from_key(_key), do: :error

  defp overlay_kind_match?(kind, normalized) do
    if Atom.to_string(kind) == normalized, do: {:ok, kind}, else: false
  end

  defp validate_disjoint_lists(left, right, path, errors) do
    overlap =
      left
      |> MapSet.new()
      |> MapSet.intersection(MapSet.new(right))
      |> MapSet.to_list()
      |> Enum.sort()

    if overlap == [] do
      errors
    else
      [
        error(path, :invalid_value, "tools allow and deny lists must not overlap", %{
          overlap: overlap
        })
        | errors
      ]
    end
  end

  defp validate_default_mode(nil, _modes, _path, errors), do: errors
  defp validate_default_mode(_default_mode, [], _path, errors), do: errors

  defp validate_default_mode(default_mode, modes, path, errors) do
    if default_mode in modes do
      errors
    else
      [
        error(
          path,
          :unknown_reference,
          "default_mode references unknown mode #{inspect(default_mode)}",
          %{
            reference: default_mode,
            allowed: modes
          }
        )
        | errors
      ]
    end
  end

  defp validate_cache_policy(policy, path, errors) do
    if policy in @cache_policies do
      errors
    else
      [
        error(
          path,
          :invalid_value,
          "cache policy must be one of #{Enum.join(@cache_policies, ", ")}",
          %{
            allowed: @cache_policies,
            value: policy
          }
        )
        | errors
      ]
    end
  end

  defp optional_string_list_field(raw, field, default, path, errors) do
    case fetch_field(raw, field) do
      :error ->
        {default, errors}

      {:ok, value} when is_list(value) ->
        {items, errors} =
          value
          |> Enum.with_index()
          |> Enum.reduce({[], errors}, fn {item, index}, {items, item_errors} ->
            case string_value(item) do
              {:ok, string} -> {[string | items], item_errors}
              :error -> {items, [type_error(path ++ [index], "string", item) | item_errors]}
            end
          end)

        items = Enum.reverse(items)
        {items, validate_unique_values(items, path, errors)}

      {:ok, value} ->
        {default, [type_error(path, "array", value) | errors]}
    end
  end

  defp validate_unique_list(items, key, path, errors) do
    items
    |> Enum.map(&Map.get(&1, key))
    |> Enum.reject(&is_nil/1)
    |> validate_unique_values(path, errors)
  end

  defp validate_unique_values(items, path, errors) do
    duplicates =
      items
      |> Enum.frequencies()
      |> Enum.filter(fn {_value, count} -> count > 1 end)
      |> Enum.map(fn {value, _count} -> value end)
      |> Enum.sort()

    Enum.reduce(duplicates, errors, fn duplicate, acc ->
      [
        error(path, :duplicate_value, "duplicate value #{inspect(duplicate)}", %{value: duplicate})
        | acc
      ]
    end)
  end

  defp unknown_reference(path, value, label, allowed_ids) do
    error(
      path,
      :unknown_reference,
      "#{path_label(path)} references unknown #{label} #{inspect(value)}",
      %{
        reference: value,
        allowed: Enum.sort(MapSet.to_list(allowed_ids))
      }
    )
  end

  defp default_overlays do
    Map.new(@overlay_kinds, &{&1, default_overlay(&1)})
  end

  defp default_overlay(:prompt), do: %{layers: [], metadata: %{}}
  defp default_overlay(:tool), do: %{allow: [], deny: [], mode: "inherit", metadata: %{}}
  defp default_overlay(:model), do: %{fallback_models: [], settings: %{}}
  defp default_overlay(:task), do: %{categories: [], modes: [], metadata: %{}}
  defp default_overlay(:schema), do: %{metadata: %{}}
  defp default_overlay(:cache), do: %{policy: "preserve", metadata: %{}}

  defp put_entry(entries, _id, nil), do: entries
  defp put_entry(entries, id, entry), do: Map.put(entries, id, entry)
end
