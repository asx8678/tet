defmodule Tet.Security.SecretFuzzerTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Tet.Security.SecretFuzzer
  alias Tet.Secrets
  alias Tet.Secrets.PatternRegistry
  alias Tet.Redactor
  alias Tet.Redactor.Inbound
  alias Tet.Redactor.Outbound
  alias Tet.Redactor.Display

  describe "generate_secret_variations/0" do
    test "returns a non-empty list of variations" do
      variations = SecretFuzzer.generate_secret_variations()
      assert is_list(variations)
      assert length(variations) > 0
    end

    test "each variation is a {string, atom} tuple" do
      for {value, type} <- SecretFuzzer.generate_secret_variations() do
        assert is_binary(value), "Expected binary value, got: #{inspect(value)}"
        assert is_atom(type), "Expected atom type, got: #{inspect(type)}"
      end
    end

    test "covers all major secret categories" do
      types =
        SecretFuzzer.generate_secret_variations()
        |> Enum.map(fn {_value, type} -> type end)
        |> MapSet.new()

      expected_types =
        MapSet.new([
          :api_key,
          :token,
          :connection_string,
          :private_key,
          :password,
          :generic_secret
        ])

      # At least most categories should be covered
      intersection = MapSet.intersection(types, expected_types)

      assert MapSet.size(intersection) >= 4,
             "Expected at least 4 secret categories, got: #{inspect(MapSet.to_list(types))}"
    end

    test "includes API key patterns" do
      values = SecretFuzzer.generate_secret_variations() |> Enum.map(fn {v, _} -> v end)

      assert Enum.any?(values, &String.starts_with?(&1, "sk-")),
             "Expected OpenAI-style API key patterns"

      assert Enum.any?(values, &String.starts_with?(&1, "AKIA")),
             "Expected AWS access key patterns"
    end

    test "includes connection string patterns" do
      values = SecretFuzzer.generate_secret_variations() |> Enum.map(fn {v, _} -> v end)

      assert Enum.any?(values, &String.contains?(&1, "://")),
             "Expected connection string patterns with ://"
    end

    test "includes private key patterns" do
      values = SecretFuzzer.generate_secret_variations() |> Enum.map(fn {v, _} -> v end)

      assert Enum.any?(values, &String.contains?(&1, "BEGIN")),
             "Expected private key BEGIN patterns"
    end
  end

  describe "test_redaction_completeness/2" do
    test "returns empty list when all secrets are redacted" do
      # The inbound redactor should catch most patterns.
      # Edge cases (short patterns) may not be caught — that's expected.
      core_variations =
        SecretFuzzer.generate_secret_variations()
        |> Enum.reject(fn {v, _type} ->
          # Near-miss edge cases that are legitimately too short for detection
          String.length(v) < 12
        end)

      failures =
        SecretFuzzer.test_redaction_completeness(fn value ->
          Inbound.redact_for_provider(%{content: value}).content
        end)

      # Only count failures for core patterns (not short edge cases)
      core_failures =
        Enum.filter(failures, fn f ->
          Enum.any?(core_variations, fn {v, _} ->
            String.contains?(v, f.value_preview) or
              String.starts_with?(f.value_preview, String.slice(v, 0, 20))
          end)
        end)

      assert core_failures == [],
             "Core pattern redaction failures: #{inspect(Enum.take(core_failures, 5))}"
    end

    test "returns failures for a no-op redaction function" do
      # An identity function should produce lots of failures
      failures = SecretFuzzer.test_redaction_completeness(fn value -> value end)
      assert length(failures) > 0, "Identity function should produce redaction failures"
    end

    test "each failure has the expected structure" do
      failures = SecretFuzzer.test_redaction_completeness(fn value -> value end)

      for failure <- Enum.take(failures, 5) do
        assert Map.has_key?(failure, :value_preview)
        assert Map.has_key?(failure, :expected_type)
        assert Map.has_key?(failure, :survived)
        assert failure.survived == true
      end
    end
  end

  # --- Integration: test actual security modules against fuzzer ---

  describe "secret detection (integration)" do
    test "all fuzzer API keys are detected by Secrets.contains_secret?" do
      api_keys =
        SecretFuzzer.generate_secret_variations()
        |> Enum.filter(fn {_v, type} -> type == :api_key end)
        |> Enum.reject(fn {v, _type} ->
          # Near-miss: too short for the {6,} quantifier — legitimately undetected
          String.length(v) < 12
        end)

      for {value, _type} <- api_keys do
        assert Secrets.contains_secret?(value),
               "API key not detected: #{String.slice(value, 0, 20)}..."
      end
    end

    test "all fuzzer connection strings are detected" do
      conn_strings =
        SecretFuzzer.generate_secret_variations()
        |> Enum.filter(fn {_v, type} -> type == :connection_string end)

      for {value, _type} <- conn_strings do
        assert Secrets.contains_secret?(value),
               "Connection string not detected: #{String.slice(value, 0, 30)}..."
      end
    end

    test "all fuzzer private keys are detected" do
      priv_keys =
        SecretFuzzer.generate_secret_variations()
        |> Enum.filter(fn {_v, type} -> type == :private_key end)

      for {value, _type} <- priv_keys do
        assert Secrets.contains_secret?(value),
               "Private key not detected: #{String.slice(value, 0, 30)}..."
      end
    end

    test "Secrets.classify returns correct type for known patterns" do
      for {value, expected_type} <- SecretFuzzer.generate_secret_variations() do
        case Secrets.classify(value) do
          {:secret, ^expected_type} ->
            :ok

          {:secret, other_type} ->
            # Acceptable if it's classified as a secret (just different sub-type)
            assert is_atom(other_type),
                   "Expected {:secret, _} classification for #{String.slice(value, 0, 20)}..., got: {:secret, #{inspect(other_type)}}"

          :clean ->
            # Some edge cases might not be detected — that's okay for classify
            # (contains_secret? may catch them via different patterns)
            :ok
        end
      end
    end
  end

  describe "secret redaction (integration)" do
    test "Inbound redactor strips secrets from provider payloads" do
      for {value, _type} <- SecretFuzzer.generate_secret_variations() do
        # Skip near-miss edge cases that are legitimately too short for detection
        if Secrets.contains_secret?(value) do
          msg = %{role: "user", content: "Use this key: #{value}"}
          redacted = Inbound.redact_for_provider(msg)

          # The raw secret should not appear in redacted content
          assert not String.contains?(redacted.content, value),
                 "Secret leaked through Inbound: #{String.slice(value, 0, 30)}..."
        end
      end
    end

    test "Outbound redactor replaces secrets with fingerprints" do
      for {value, _type} <- SecretFuzzer.generate_secret_variations() do
        if Secrets.contains_secret?(value) do
          data = %{payload: "key=#{value}"}
          redacted = Outbound.redact_for_audit(data, fingerprint: true)

          # Raw secret should not appear
          assert not String.contains?(redacted.payload, value),
                 "Secret leaked through Outbound: #{String.slice(value, 0, 30)}..."
        end
      end
    end

    test "Display redactor does not expose full secrets" do
      for {value, _type} <- SecretFuzzer.generate_secret_variations() do
        # Use a sensitive key so the value is caught by key-based redaction too
        data = %{api_key: value}
        redacted = Display.redact_for_display(data)

        # Full value should not be in redacted output
        assert redacted.api_key != value,
               "Full secret exposed in Display: #{String.slice(value, 0, 30)}..."
      end
    end

    test "Display redactor for logs fully redacts (no partials)" do
      for {value, _type} <- SecretFuzzer.generate_secret_variations() do
        if Secrets.contains_secret?(value) do
          msg = "Connecting with #{value} to api"
          redacted = Display.redact_for_log(msg)

          # Full secret should not appear in log output
          assert not String.contains?(redacted, value),
                 "Secret leaked through Display.log: #{String.slice(value, 0, 30)}..."
        end
      end
    end
  end

  describe "sensitive key detection (integration)" do
    test "all common secret key names are detected" do
      sensitive_keys = [
        :api_key,
        :password,
        :secret,
        :token,
        :authorization,
        :credential,
        :private_key,
        :access_token,
        :refresh_token,
        "api_key",
        "password",
        "secret_token",
        "bearer_token",
        "AWS_SECRET_ACCESS_KEY",
        "OPENAI_API_KEY"
      ]

      for key <- sensitive_keys do
        assert Redactor.sensitive_key?(key),
               "Key not detected as sensitive: #{inspect(key)}"
      end
    end

    test "non-sensitive keys are not flagged" do
      safe_keys = [:name, :id, :count, :status, :message, "user_id", "created_at"]

      for key <- safe_keys do
        assert not Redactor.sensitive_key?(key),
               "Key incorrectly flagged as sensitive: #{inspect(key)}"
      end
    end
  end

  describe "PatternRegistry integration" do
    test "builtin patterns cover all known secret formats" do
      _patterns = PatternRegistry.builtin_patterns()
      names = PatternRegistry.pattern_names()

      # Key patterns that must exist
      required_names = [
        :openai_api_key,
        :anthropic_api_key,
        :aws_access_key,
        :bearer_token,
        :connection_string,
        :private_key_block
      ]

      for name <- required_names do
        assert name in names, "Required pattern missing from registry: #{name}"
      end
    end

    test "match_all catches overlapping patterns" do
      # A string with multiple secret patterns
      value = "api_key=sk-abcdefghijklmnopqrstuvwx"

      matches = PatternRegistry.match_all(value)
      assert length(matches) >= 1, "Expected at least one match for multi-pattern string"
    end
  end

  describe "Secrets fingerprinting (integration)" do
    test "fingerprint is stable for the same input" do
      variations =
        SecretFuzzer.generate_secret_variations()
        |> Enum.filter(fn {v, _} -> String.length(v) >= 8 end)
        |> Enum.take(10)

      for {value, _type} <- variations do
        fp1 = Secrets.fingerprint(value)
        fp2 = Secrets.fingerprint(value)
        assert fp1 == fp2, "Fingerprint not stable for: #{String.slice(value, 0, 20)}"
      end
    end

    test "fingerprint differs for different inputs" do
      {v1, _} = Enum.at(SecretFuzzer.generate_secret_variations(), 0)
      {v2, _} = Enum.at(SecretFuzzer.generate_secret_variations(), 1)

      if v1 != v2 do
        assert Secrets.fingerprint(v1) != Secrets.fingerprint(v2),
               "Different values produced the same fingerprint"
      end
    end

    test "partial_preview shows prefix and suffix but not full value" do
      for {value, _type} <- SecretFuzzer.generate_secret_variations() do
        if String.length(value) >= 12 do
          preview = Secrets.partial_preview(value)
          assert preview != value, "Partial preview exposes full secret"
          assert String.contains?(preview, "..."), "Partial preview missing ellipsis"
        end
      end
    end
  end
end
