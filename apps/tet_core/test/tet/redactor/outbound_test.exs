defmodule Tet.Redactor.OutboundTest do
  use ExUnit.Case, async: true

  alias Tet.Redactor.Outbound

  @openai_key "sk-proj-abcdefghijklmnopqrstuvwx"
  @anthropic_key "sk-ant-api03-abcdefghijklmnopqrstu"
  @connection_string "postgres://admin:supersecret@prod.db.example.com:5432/myapp"

  describe "redact_for_audit/1" do
    test "redacts API keys in event data" do
      event = %{action: "llm_call", api_key: @openai_key, model: "gpt-4"}
      result = Outbound.redact_for_audit(event)

      assert result.api_key == "[REDACTED]"
      assert result.model == "gpt-4"
    end

    test "redacts secrets in string values" do
      event = %{payload: "Using key #{@openai_key} for request"}
      result = Outbound.redact_for_audit(event)

      refute String.contains?(result.payload, @openai_key)
      assert String.contains?(result.payload, "[REDACTED]")
    end

    test "redacts connection strings" do
      event = %{config: "url=#{@connection_string}"}
      result = Outbound.redact_for_audit(event)

      refute String.contains?(result.config, "supersecret")
    end

    test "preserves structural metadata" do
      event = %{
        timestamp: "2025-05-01T00:00:00Z",
        action: "tool_call",
        tool: "read_file",
        provider: %{api_key: "secret-value", region: "us-east-1"},
        result: :ok
      }

      result = Outbound.redact_for_audit(event)
      assert result.timestamp == "2025-05-01T00:00:00Z"
      assert result.action == "tool_call"
      assert result.tool == "read_file"
      assert result.provider.api_key == "[REDACTED]"
      assert result.provider.region == "us-east-1"
      assert result.result == :ok
    end

    test "handles nested maps recursively" do
      event = %{
        request: %{
          headers: %{authorization: "Bearer xyz"},
          body: %{prompt: "hello"}
        }
      }

      result = Outbound.redact_for_audit(event)
      assert result.request.headers.authorization == "[REDACTED]"
      assert result.request.body.prompt == "hello"
    end
  end

  describe "redact_for_audit/2 with fingerprint" do
    test "replaces secrets with fingerprints when enabled" do
      event = %{api_key: @openai_key, model: "gpt-4"}
      result = Outbound.redact_for_audit(event, fingerprint: true)

      assert String.starts_with?(result.api_key, "fp:")
      assert result.model == "gpt-4"
    end

    test "fingerprints are stable across calls" do
      event = %{api_key: @openai_key}

      result1 = Outbound.redact_for_audit(event, fingerprint: true)
      result2 = Outbound.redact_for_audit(event, fingerprint: true)

      assert result1.api_key == result2.api_key
    end

    test "fingerprints secrets in string content" do
      event = %{payload: "key=#{@openai_key}"}
      result = Outbound.redact_for_audit(event, fingerprint: true)

      refute String.contains?(result.payload, @openai_key)
      assert String.contains?(result.payload, "fp:")
    end

    test "different secrets produce different fingerprints" do
      event1 = %{api_key: @openai_key}
      event2 = %{api_key: @anthropic_key}

      result1 = Outbound.redact_for_audit(event1, fingerprint: true)
      result2 = Outbound.redact_for_audit(event2, fingerprint: true)

      assert result1.api_key != result2.api_key
    end
  end

  describe "redact_for_store/1" do
    test "redacts secrets before persistence" do
      record = %{
        config: %{password: "hunter2", host: "localhost"},
        name: "production"
      }

      result = Outbound.redact_for_store(record)
      assert result.config.password == "[REDACTED]"
      assert result.config.host == "localhost"
      assert result.name == "production"
    end

    test "strips connection strings from stored data" do
      record = %{database_url: @connection_string, pool_size: 10}
      result = Outbound.redact_for_store(record)

      # database_url doesn't match sensitive key pattern, but value has secret
      # Actually let me check... it won't match the key but will match the value
      refute String.contains?(inspect(result), "supersecret")
    end

    test "handles lists in store data" do
      records = [
        %{api_key: "key1", id: 1},
        %{api_key: "key2", id: 2}
      ]

      result = Outbound.redact_for_store(records)
      assert Enum.all?(result, fn r -> r.api_key == "[REDACTED]" end)
      assert Enum.map(result, & &1.id) == [1, 2]
    end
  end

  describe "redact_for_store/2 with fingerprint" do
    test "supports fingerprint mode for store" do
      record = %{secret: "mysecretvalue123", id: "abc"}
      result = Outbound.redact_for_store(record, fingerprint: true)

      assert String.starts_with?(result.secret, "fp:")
      assert result.id == "abc"
    end
  end

  describe "BD-0068 regression: short sk- keys redacted" do
    test "sk-proj style keys are redacted in audit" do
      secret = "sk-proj-abc123def456"
      event = %{payload: "prefix #{secret} suffix"}
      result = Outbound.redact_for_audit(event)

      refute String.contains?(result.payload, secret)
    end

    test "short sk-ant keys are redacted in audit" do
      secret = "sk-ant-api03-shortkey"
      event = %{payload: "prefix #{secret} suffix"}
      result = Outbound.redact_for_audit(event)

      refute String.contains?(result.payload, secret)
    end

    test "short sk- keys are redacted in audit" do
      secret = "sk-abcdef123456"
      event = %{payload: "prefix #{secret} suffix"}
      result = Outbound.redact_for_audit(event)

      refute String.contains?(result.payload, secret)
    end

    test "sk-proj keys are redacted in store" do
      secret = "sk-proj-abc123def456"
      record = %{data: "key=#{secret}"}
      result = Outbound.redact_for_store(record)

      refute String.contains?(result.data, secret)
    end
  end

  describe "secrets never leak" do
    test "no secret survives audit redaction" do
      event = %{
        nested: %{
          deep: %{
            config: "token=#{@openai_key}",
            password: @anthropic_key,
            url: @connection_string
          }
        }
      }

      result = Outbound.redact_for_audit(event)
      serialized = inspect(result)
      refute String.contains?(serialized, @openai_key)
      refute String.contains?(serialized, @anthropic_key)
      refute String.contains?(serialized, "supersecret")
    end
  end
end
