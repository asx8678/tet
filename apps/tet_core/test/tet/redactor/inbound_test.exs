defmodule Tet.Redactor.InboundTest do
  use ExUnit.Case, async: true

  alias Tet.Redactor.Inbound

  @openai_key "sk-proj-abcdefghijklmnopqrstuvwx"
  @anthropic_key "sk-ant-api03-abcdefghijklmnopqrstu"
  @bearer_token "Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.payload.signature"
  @connection_string "postgres://admin:supersecret@prod.db.example.com:5432/myapp"
  @private_key "-----BEGIN RSA PRIVATE KEY-----\nMIIE...content..."

  describe "redact_for_provider/1" do
    test "redacts OpenAI API keys from message content" do
      msg = %{role: "user", content: "Use this key: #{@openai_key}"}
      result = Inbound.redact_for_provider(msg)

      refute String.contains?(result.content, @openai_key)
      assert String.contains?(result.content, "[REDACTED]")
    end

    test "redacts Anthropic API keys" do
      msg = %{content: "Key is #{@anthropic_key}"}
      result = Inbound.redact_for_provider(msg)

      refute String.contains?(result.content, @anthropic_key)
    end

    test "redacts Bearer tokens" do
      msg = %{headers: "Authorization: #{@bearer_token}"}
      result = Inbound.redact_for_provider(msg)

      refute String.contains?(result.headers, "eyJhbGci")
    end

    test "redacts connection strings" do
      msg = %{content: "Connect to #{@connection_string}"}
      result = Inbound.redact_for_provider(msg)

      refute String.contains?(result.content, "supersecret")
    end

    test "redacts private key blocks" do
      msg = %{content: "Key: #{@private_key}"}
      result = Inbound.redact_for_provider(msg)

      refute String.contains?(result.content, "BEGIN RSA PRIVATE KEY")
    end

    test "redacts values under sensitive keys" do
      msg = %{api_key: "some-value", content: "hello"}
      result = Inbound.redact_for_provider(msg)

      assert result.api_key == "[REDACTED]"
      assert result.content == "hello"
    end

    test "handles nested maps" do
      msg = %{
        config: %{
          database: %{password: "hunter2", host: "localhost"},
          name: "prod"
        }
      }

      result = Inbound.redact_for_provider(msg)
      assert result.config.database.password == "[REDACTED]"
      assert result.config.database.host == "localhost"
      assert result.config.name == "prod"
    end

    test "handles lists" do
      msgs = [
        %{role: "user", content: "Key: #{@openai_key}"},
        %{role: "assistant", content: "OK"}
      ]

      result = Inbound.redact_for_provider(msgs)
      refute String.contains?(hd(result).content, @openai_key)
      assert List.last(result).content == "OK"
    end

    test "preserves non-sensitive values" do
      msg = %{role: "user", content: "Hello, how are you?", model: "gpt-4"}
      result = Inbound.redact_for_provider(msg)

      assert result.role == "user"
      assert result.content == "Hello, how are you?"
      assert result.model == "gpt-4"
    end

    test "handles nil and other primitives gracefully" do
      assert Inbound.redact_for_provider(nil) == nil
      assert Inbound.redact_for_provider(42) == 42
      assert Inbound.redact_for_provider(true) == true
    end
  end

  describe "redact_tool_result/1" do
    test "redacts secrets from tool output" do
      result = %{
        output: "Connected to #{@connection_string}",
        exit_code: 0
      }

      redacted = Inbound.redact_tool_result(result)
      refute String.contains?(redacted.output, "supersecret")
      assert redacted.exit_code == 0
    end

    test "redacts API keys in tool output" do
      result = %{output: "Found key #{@openai_key} in .env"}
      redacted = Inbound.redact_tool_result(result)

      refute String.contains?(redacted.output, @openai_key)
    end

    test "handles complex nested tool results" do
      result = %{
        files: [
          %{path: ".env", content: "API_KEY=#{@openai_key}"},
          %{path: "readme.md", content: "No secrets here"}
        ]
      }

      redacted = Inbound.redact_tool_result(result)
      [env_file, readme] = redacted.files
      refute String.contains?(env_file.content, @openai_key)
      assert readme.content == "No secrets here"
    end
  end

  describe "redact_for_provider/2 with custom patterns" do
    test "uses custom patterns when provided" do
      custom = [{:custom_key, ~r/MYAPP-[A-Z0-9]{10,}/, :api_key}]
      msg = %{content: "Key: MYAPP-ABCDEF1234"}

      result = Inbound.redact_for_provider(msg, patterns: custom)
      refute String.contains?(result.content, "MYAPP-ABCDEF1234")
    end
  end

  describe "BD-0068 regression: short sk- keys redacted" do
    test "sk-proj style keys are redacted" do
      secret = "sk-proj-abc123def456"
      msg = %{content: "prefix #{secret} suffix"}
      result = Inbound.redact_for_provider(msg)

      refute String.contains?(result.content, secret)
    end

    test "short sk-ant keys are redacted" do
      secret = "sk-ant-api03-shortkey"
      msg = %{content: "prefix #{secret} suffix"}
      result = Inbound.redact_for_provider(msg)

      refute String.contains?(result.content, secret)
    end

    test "short sk- keys are redacted" do
      secret = "sk-abcdef123456"
      msg = %{content: "prefix #{secret} suffix"}
      result = Inbound.redact_for_provider(msg)

      refute String.contains?(result.content, secret)
    end

    test "sk-proj keys are redacted via redact_for_provider/1 on plain string" do
      secret = "sk-proj-abc123def456"
      payload = "prefix #{secret} suffix"
      result = Inbound.redact_for_provider(payload)

      refute String.contains?(result, secret)
    end
  end

  describe "secrets never leak" do
    test "no secret survives deep nesting" do
      deep = %{
        a: %{b: %{c: %{d: %{e: "secret=#{@openai_key}"}}}}
      }

      result = Inbound.redact_for_provider(deep)
      serialized = inspect(result)
      refute String.contains?(serialized, @openai_key)
    end

    test "secrets in tuples are redacted" do
      data = {:config, "key", @openai_key}
      result = Inbound.redact_for_provider(data)
      serialized = inspect(result)
      refute String.contains?(serialized, @openai_key)
    end
  end
end
