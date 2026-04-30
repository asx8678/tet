defmodule Tet.ModelRegistryTest do
  use ExUnit.Case, async: true

  alias Tet.ModelRegistry
  alias Tet.ModelRegistry.Error

  @fixture_dir Path.expand("../fixtures/model_registry", __DIR__)
  @openai_model "openai/gpt-4o-mini"

  test "valid registry declares providers, model capabilities, and profile pins" do
    assert {:ok, registry} = load_registry("valid.json")

    assert registry.schema_version == 1
    assert Map.keys(registry.providers) == ["mock", "openai_compatible"]
    assert registry.providers["openai_compatible"].type == "openai_compatible"
    assert registry.providers["openai_compatible"].config["api_key_env"] == "TET_OPENAI_API_KEY"

    assert {:ok, capabilities} = ModelRegistry.capabilities(registry, @openai_model)
    assert capabilities.context.window_tokens == 128_000
    assert capabilities.context.max_output_tokens == 16_384
    assert capabilities.cache.supported
    assert capabilities.cache.prompt
    assert capabilities.tool_calls.supported
    assert capabilities.tool_calls.parallel

    assert {:ok, chat_pin} = ModelRegistry.profile_pin(registry, "chat")
    assert chat_pin.default_model == @openai_model
    assert chat_pin.fallback_models == ["mock/default"]

    assert {:ok, model} = ModelRegistry.pinned_model(registry, :chat)
    assert model.id == @openai_model
    assert model.provider == "openai_compatible"
    assert model.model == "gpt-4o-mini"
  end

  test "from_json returns actionable invalid JSON errors" do
    assert {:error, [%Error{} = error]} = ModelRegistry.from_json("{nope")

    assert error.path == []
    assert error.code == :invalid_json
    assert error.message == "registry JSON is invalid"
    assert is_binary(error.details.detail)
    assert ModelRegistry.format_error(error) =~ "registry:"
  end

  test "validates root object shape" do
    assert {:error, [%Error{} = error]} = ModelRegistry.validate(["nope"])

    assert error.path == []
    assert error.code == :invalid_type
    assert error.details.expected == "object"
  end

  describe "string field validation" do
    test "rejects JSON boolean and null model names" do
      for {value, actual_type} <- [{true, "boolean"}, {nil, "null"}] do
        raw = put_path(valid_raw(), ["models", @openai_model, "model"], value)

        assert_invalid_type(
          raw,
          ["models", @openai_model, "model"],
          "non-empty string",
          actual_type
        )
      end
    end

    test "rejects JSON boolean provider types" do
      raw = put_path(valid_raw(), ["providers", "mock", "type"], false)

      assert_invalid_type(raw, ["providers", "mock", "type"], "non-empty string", "boolean")
    end
  end

  describe "context capability validation" do
    test "requires context capability" do
      raw = valid_raw() |> delete_path(["models", @openai_model, "capabilities", "context"])

      assert_error(raw, ["models", @openai_model, "capabilities", "context"], :required)
    end

    test "requires positive context window" do
      raw =
        put_path(
          valid_raw(),
          ["models", @openai_model, "capabilities", "context", "window_tokens"],
          0
        )

      error =
        assert_error(
          raw,
          ["models", @openai_model, "capabilities", "context", "window_tokens"],
          :invalid_type
        )

      assert error.details.expected == "positive integer"
      assert error.details.actual == "integer"
    end

    test "rejects output windows larger than the context window" do
      raw =
        put_path(
          valid_raw(),
          ["models", @openai_model, "capabilities", "context", "max_output_tokens"],
          256_000
        )

      error =
        assert_error(
          raw,
          ["models", @openai_model, "capabilities", "context", "max_output_tokens"],
          :invalid_value
        )

      assert error.details.max_output_tokens == 256_000
      assert error.details.window_tokens == 128_000
    end
  end

  describe "cache capability validation" do
    test "requires cache capability" do
      raw = valid_raw() |> delete_path(["models", @openai_model, "capabilities", "cache"])

      assert_error(raw, ["models", @openai_model, "capabilities", "cache"], :required)
    end

    test "requires boolean cache support declaration" do
      raw =
        put_path(
          valid_raw(),
          ["models", @openai_model, "capabilities", "cache", "supported"],
          "yes"
        )

      error =
        assert_error(
          raw,
          ["models", @openai_model, "capabilities", "cache", "supported"],
          :invalid_type
        )

      assert error.details.expected == "boolean"
      assert error.details.actual == "string"
    end
  end

  describe "tool-call capability validation" do
    test "requires tool-call capability" do
      raw = valid_raw() |> delete_path(["models", @openai_model, "capabilities", "tool_calls"])

      assert_error(raw, ["models", @openai_model, "capabilities", "tool_calls"], :required)
    end

    test "requires boolean tool-call support declaration" do
      raw =
        put_path(
          valid_raw(),
          ["models", @openai_model, "capabilities", "tool_calls", "supported"],
          "sometimes"
        )

      error =
        assert_error(
          raw,
          ["models", @openai_model, "capabilities", "tool_calls", "supported"],
          :invalid_type
        )

      assert error.details.expected == "boolean"
      assert error.details.actual == "string"
    end
  end

  describe "reference validation" do
    test "requires model provider references" do
      raw = valid_raw() |> delete_path(["models", @openai_model, "provider"])

      assert_error(raw, ["models", @openai_model, "provider"], :required)
    end

    test "rejects unknown model provider references" do
      raw = put_path(valid_raw(), ["models", @openai_model, "provider"], "missing_provider")

      error = assert_error(raw, ["models", @openai_model, "provider"], :unknown_reference)
      assert error.details.reference == "missing_provider"
      assert error.details.allowed == ["mock", "openai_compatible"]
    end

    test "rejects boolean model provider references as invalid type before lookup" do
      path = ["models", @openai_model, "provider"]
      raw = put_path(valid_raw(), path, true)

      assert_invalid_type(raw, path, "non-empty string", "boolean")
      refute_error(raw, path, :unknown_reference)
    end

    test "requires profile default model references" do
      raw = valid_raw() |> delete_path(["profile_pins", "chat", "default_model"])

      assert_error(raw, ["profile_pins", "chat", "default_model"], :required)
    end

    test "rejects unknown profile default model references" do
      raw = put_path(valid_raw(), ["profile_pins", "chat", "default_model"], "missing/model")

      error = assert_error(raw, ["profile_pins", "chat", "default_model"], :unknown_reference)
      assert error.details.reference == "missing/model"
      assert error.details.allowed == ["mock/default", @openai_model]
    end

    test "rejects null profile default model references as invalid type before lookup" do
      path = ["profile_pins", "chat", "default_model"]
      raw = put_path(valid_raw(), path, nil)

      assert_invalid_type(raw, path, "non-empty string", "null")
      refute_error(raw, path, :unknown_reference)
    end

    test "rejects unknown profile fallback model references" do
      raw = put_path(valid_raw(), ["profile_pins", "chat", "fallback_models"], ["missing/model"])

      error =
        assert_error(raw, ["profile_pins", "chat", "fallback_models", 0], :unknown_reference)

      assert error.details.reference == "missing/model"
    end

    test "rejects boolean fallback model references as invalid type before lookup" do
      path = ["profile_pins", "chat", "fallback_models", 0]
      raw = put_path(valid_raw(), ["profile_pins", "chat", "fallback_models"], [true])

      assert_invalid_type(raw, path, "string", "boolean")
      refute_error(raw, path, :unknown_reference)
    end
  end

  defp load_registry(name) do
    name
    |> fixture_path()
    |> File.read!()
    |> ModelRegistry.from_json()
  end

  defp valid_raw do
    "valid.json"
    |> fixture_path()
    |> File.read!()
    |> :json.decode()
  end

  defp fixture_path(name), do: Path.join(@fixture_dir, name)

  defp put_path(raw, path, value), do: put_in(raw, path, value)

  defp delete_path(raw, path) do
    {_value, updated} = pop_in(raw, path)
    updated
  end

  defp assert_invalid_type(raw, path, expected, actual) do
    error = assert_error(raw, path, :invalid_type)

    assert error.details.expected == expected
    assert error.details.actual == actual

    error
  end

  defp assert_error(raw, path, code) do
    assert {:error, errors} = ModelRegistry.validate(raw)

    assert %Error{} =
             error = Enum.find(errors, fn error -> error.path == path and error.code == code end),
           "expected #{inspect(code)} at #{inspect(path)}, got #{inspect(errors)}"

    assert is_binary(error.message)
    assert is_map(error.details)
    error
  end

  defp refute_error(raw, path, code) do
    assert {:error, errors} = ModelRegistry.validate(raw)

    refute Enum.any?(errors, fn error -> error.path == path and error.code == code end),
           "expected no #{inspect(code)} at #{inspect(path)}, got #{inspect(errors)}"
  end
end
