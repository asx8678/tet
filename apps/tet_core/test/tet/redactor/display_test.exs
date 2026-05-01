defmodule Tet.Redactor.DisplayTest do
  use ExUnit.Case, async: true

  alias Tet.Redactor.Display

  @openai_key "sk-proj-abcdefghijklmnopqrstuvwx"
  @anthropic_key "sk-ant-api03-abcdefghijklmnopqrstu"
  @bearer_token "Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.payload.signature"

  describe "redact_for_display/1" do
    test "shows partial values by default" do
      data = %{api_key: @openai_key, name: "test"}
      result = Display.redact_for_display(data)

      # Sensitive key value gets partial preview
      refute result.api_key == @openai_key
      refute result.api_key == "[REDACTED]"
      assert String.contains?(result.api_key, "...")
      assert result.name == "test"
    end

    test "redacts secrets in string content with partial preview" do
      data = %{content: "Using key #{@openai_key} now"}
      result = Display.redact_for_display(data)

      refute String.contains?(result.content, @openai_key)
      assert String.contains?(result.content, "...")
    end

    test "handles Bearer tokens with partial display" do
      data = %{header: "Authorization: #{@bearer_token}"}
      result = Display.redact_for_display(data)

      refute String.contains?(result.header, "eyJhbGci")
      assert String.contains?(result.header, "...")
    end

    test "preserves non-sensitive data completely" do
      data = %{model: "gpt-4", temperature: 0.7, content: "Hello world"}
      result = Display.redact_for_display(data)

      assert result.model == "gpt-4"
      assert result.temperature == 0.7
      assert result.content == "Hello world"
    end

    test "handles nested structures" do
      data = %{
        config: %{
          provider: %{api_key: "very-secret-token-value", name: "openai"},
          endpoint: "https://api.example.com"
        }
      }

      result = Display.redact_for_display(data)
      assert result.config.provider.api_key != "very-secret-token-value"
      assert String.contains?(result.config.provider.api_key, "...")
      assert result.config.provider.name == "openai"
      assert result.config.endpoint == "https://api.example.com"
    end

    test "handles lists" do
      data = [
        %{api_key: @openai_key, id: 1},
        %{api_key: @anthropic_key, id: 2}
      ]

      result = Display.redact_for_display(data)
      assert Enum.all?(result, fn r -> r.api_key != @openai_key end)
      assert Enum.all?(result, fn r -> String.contains?(r.api_key, "...") end)
    end
  end

  describe "redact_for_display/2 with partial: false" do
    test "fully redacts when partial is disabled" do
      data = %{api_key: @openai_key, name: "test"}
      result = Display.redact_for_display(data, partial: false)

      assert result.api_key == "[REDACTED]"
      assert result.name == "test"
    end

    test "fully redacts string content secrets" do
      data = %{content: "Key: #{@openai_key}"}
      result = Display.redact_for_display(data, partial: false)

      refute String.contains?(result.content, @openai_key)
      assert String.contains?(result.content, "[REDACTED]")
      refute String.contains?(result.content, "...")
    end
  end

  describe "redact_for_log/1" do
    test "always fully redacts (no partials)" do
      msg = "Connecting with #{@openai_key} to api"
      result = Display.redact_for_log(msg)

      refute String.contains?(result, @openai_key)
      assert String.contains?(result, "[REDACTED]")
      # Should NOT show partial
      refute Regex.match?(~r/sk-p\.\.\./, result)
    end

    test "redacts all secret types in log messages" do
      msg = "Auth: #{@bearer_token}, Key: #{@anthropic_key}"
      result = Display.redact_for_log(msg)

      refute String.contains?(result, "eyJhbGci")
      refute String.contains?(result, "sk-ant")
      assert String.contains?(result, "[REDACTED]")
    end

    test "redacts maps for logging" do
      data = %{password: "secret123", action: "login"}
      result = Display.redact_for_log(data)

      assert result.password == "[REDACTED]"
      assert result.action == "login"
    end

    test "handles nested data in logs" do
      data = %{
        event: "request",
        meta: %{
          api_key: @openai_key,
          timestamp: "2025-01-01"
        }
      }

      result = Display.redact_for_log(data)
      assert result.meta.api_key == "[REDACTED]"
      assert result.meta.timestamp == "2025-01-01"
    end
  end

  describe "secrets never leak" do
    test "no secret visible in display output" do
      data = %{
        messages: [
          %{role: "system", content: "Use #{@openai_key}"},
          %{role: "user", content: "Connect to #{@anthropic_key}"}
        ],
        credentials: %{bearer: @bearer_token}
      }

      result = Display.redact_for_display(data)
      serialized = inspect(result)

      refute String.contains?(serialized, @openai_key)
      refute String.contains?(serialized, @anthropic_key)
      refute String.contains?(serialized, "eyJhbGci")
    end

    test "no secret visible in log output" do
      data = %{
        config: %{
          api_key: @openai_key,
          secret: @anthropic_key,
          url: "postgres://user:password123@host/db"
        }
      }

      result = Display.redact_for_log(data)
      serialized = inspect(result)

      refute String.contains?(serialized, @openai_key)
      refute String.contains?(serialized, @anthropic_key)
      refute String.contains?(serialized, "password123")
    end
  end
end
