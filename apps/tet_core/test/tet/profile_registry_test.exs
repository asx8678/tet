defmodule Tet.ProfileRegistryTest do
  use ExUnit.Case, async: true

  alias Tet.ProfileRegistry
  alias Tet.ProfileRegistry.Error

  @fixture_dir Path.expand("../fixtures/profile_registry", __DIR__)
  @model_registry_fixture Path.expand("../fixtures/model_registry/valid.json", __DIR__)
  @openai_model "openai/gpt-4o-mini"

  test "valid registry declares inspectable prompt/tool/model/task/schema/cache overlays" do
    assert {:ok, model_registry} = load_model_registry()
    assert {:ok, registry} = load_registry("valid.json", model_registry: model_registry)

    assert registry.schema_version == 1
    assert Map.keys(registry.profiles) == ["chat"]

    assert [%{id: "chat", default_model: @openai_model} = summary] =
             ProfileRegistry.list_profiles(registry)

    assert summary.overlay_kinds == [:prompt, :tool, :model, :task, :schema, :cache]
    assert summary.tags == ["chat", "coding"]

    assert {:ok, profile} = ProfileRegistry.profile(registry, :chat)
    assert profile.display_name == "Chat"
    assert profile.overlays.prompt.system == "You are Tet in chat mode."

    assert [%{id: "style", content: "Be direct and cite assumptions."}] =
             profile.overlays.prompt.layers

    assert profile.overlays.tool.allow == ["native.list_files", "native.read_file"]
    assert profile.overlays.model.default_model == @openai_model
    assert profile.overlays.model.fallback_models == ["mock/default"]
    assert profile.overlays.task.default_mode == "assist"
    assert profile.overlays.schema.response["type"] == "object"
    assert profile.overlays.cache.ttl_seconds == 900

    assert {:ok, model_overlay} = ProfileRegistry.overlay(registry, "chat", "model")
    assert model_overlay.profile_pin == "chat"

    assert {:ok, tool_overlay} = ProfileRegistry.overlay(registry, "chat", "tools")
    assert tool_overlay.allow == ["native.list_files", "native.read_file"]
  end

  test "from_json returns actionable invalid JSON errors" do
    assert {:error, [%Error{} = error]} = ProfileRegistry.from_json("{nope")

    assert error.path == []
    assert error.code == :invalid_json
    assert error.message == "profile registry JSON is invalid"
    assert is_binary(error.details.detail)
    assert ProfileRegistry.format_error(error) =~ "profile registry:"
  end

  test "validates root object shape" do
    assert {:error, [%Error{} = error]} = ProfileRegistry.validate(["nope"])

    assert error.path == []
    assert error.code == :invalid_type
    assert error.details.expected == "object"
    assert error.details.actual == "array"
  end

  test "requires all overlay kinds for every descriptor" do
    raw = valid_raw() |> delete_path(["profiles", "chat", "overlays", "cache"])

    error = assert_error(raw, ["profiles", "chat", "overlays", "cache"], :required)
    assert error.message =~ "cache is required"
  end

  test "rejects unknown overlay kinds" do
    raw = put_path(valid_raw(), ["profiles", "chat", "overlays", "telepathy"], %{})

    error = assert_error(raw, ["profiles", "chat", "overlays", ~s("telepathy")], :unknown_overlay)
    assert error.details.allowed == ["prompt", "tool", "model", "task", "schema", "cache"]
  end

  test "rejects overlay aliases and normalized variants instead of silently ignoring them" do
    invalid_keys = ["tools", " Tool ", "Tool", "MODEL", "prompt "]

    Enum.each(invalid_keys, fn key ->
      raw = put_path(valid_raw(), ["profiles", "chat", "overlays", key], %{"extra" => true})

      error =
        assert_error(raw, ["profiles", "chat", "overlays", inspect(key)], :unknown_overlay)

      assert error.message == "unknown overlay kind #{inspect(key)}"
      assert error.details.allowed == ["prompt", "tool", "model", "task", "schema", "cache"]
    end)
  end

  test "rejects invalid prompt layer fields before runtime prompt composition" do
    raw =
      put_path(
        valid_raw(),
        ["profiles", "chat", "overlays", "prompt", "layers", 0, "content"],
        true
      )

    error =
      assert_error(
        raw,
        ["profiles", "chat", "overlays", "prompt", "layers", 0, "content"],
        :invalid_type
      )

    assert error.details.expected == "non-empty string"
    assert error.details.actual == "boolean"
  end

  test "rejects overlapping allow and deny tools" do
    raw =
      put_path(valid_raw(), ["profiles", "chat", "overlays", "tool", "deny"], [
        "native.read_file"
      ])

    error = assert_error(raw, ["profiles", "chat", "overlays", "tool"], :invalid_value)
    assert error.details.overlap == ["native.read_file"]
  end

  test "rejects model references missing from the model registry" do
    assert {:ok, model_registry} = load_model_registry()

    raw =
      put_path(
        valid_raw(),
        ["profiles", "chat", "overlays", "model", "default_model"],
        "missing/model"
      )

    error =
      assert_error(
        raw,
        ["profiles", "chat", "overlays", "model", "default_model"],
        :unknown_reference,
        model_registry: model_registry
      )

    assert error.details.reference == "missing/model"
    assert @openai_model in error.details.allowed
  end

  test "requires a model overlay selection" do
    raw =
      valid_raw()
      |> delete_path(["profiles", "chat", "overlays", "model", "default_model"])
      |> delete_path(["profiles", "chat", "overlays", "model", "profile_pin"])

    error = assert_error(raw, ["profiles", "chat", "overlays", "model"], :required)
    assert error.message =~ "default_model or profile_pin"
  end

  test "rejects task default modes outside declared modes" do
    raw = put_path(valid_raw(), ["profiles", "chat", "overlays", "task", "default_mode"], "act")

    error =
      assert_error(
        raw,
        ["profiles", "chat", "overlays", "task", "default_mode"],
        :unknown_reference
      )

    assert error.details.reference == "act"
    assert error.details.allowed == ["assist", "plan"]
  end

  test "rejects unsupported cache policies" do
    raw =
      put_path(valid_raw(), ["profiles", "chat", "overlays", "cache", "policy"], "forever-ish")

    error = assert_error(raw, ["profiles", "chat", "overlays", "cache", "policy"], :invalid_value)
    assert error.details.allowed == ["preserve", "drop", "replace"]
  end

  defp load_registry(name, opts) do
    name
    |> fixture_path()
    |> File.read!()
    |> ProfileRegistry.from_json(opts)
  end

  defp load_model_registry do
    @model_registry_fixture
    |> File.read!()
    |> Tet.ModelRegistry.from_json()
  end

  defp valid_raw do
    "valid.json"
    |> fixture_path()
    |> File.read!()
    |> :json.decode()
  end

  defp assert_error(raw, path, code, opts \\ []) do
    assert {:error, errors} = ProfileRegistry.validate(raw, opts)
    assert %Error{} = error = Enum.find(errors, &(&1.path == path and &1.code == code))
    error
  end

  defp fixture_path(name), do: Path.join(@fixture_dir, name)

  defp put_path(raw, path, value), do: put_in(raw, access_path(path), value)

  defp delete_path(raw, path) do
    {_value, updated} = pop_in(raw, access_path(path))
    updated
  end

  defp access_path(path) do
    Enum.map(path, fn
      index when is_integer(index) -> Access.at(index)
      key -> key
    end)
  end
end
