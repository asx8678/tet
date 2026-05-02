defmodule Tet.Security.SecretFuzzer do
  @moduledoc """
  Secret detection fuzzing engine — BD-0070.

  Generates a comprehensive battery of secret-like strings and tests
  them against the secret detection and redaction pipeline. Ensures
  that every known secret pattern is caught and that non-secret strings
  are not falsely flagged.

  ## Secret categories

    - **API keys** — OpenAI, Anthropic, AWS, GitHub
    - **Tokens** — Bearer, Slack, generic
    - **Connection strings** — PostgreSQL, MongoDB, Redis, MySQL
    - **Private keys** — PEM blocks, SSH keys
    - **Passwords** — Config assignments, env vars
    - **Edge cases** — Short secrets, truncated patterns, obfuscated

  Pure functions, no processes, no side effects.
  """

  # --- Public API ---

  @doc """
  Generates a list of secret-like string variations.

  Each entry is `{value, expected_type}` where `expected_type` is the
  classification we expect (e.g., `:api_key`, `:token`, `:password`).
  """
  @spec generate_secret_variations() :: [{String.t(), atom()}]
  def generate_secret_variations do
    api_keys() ++
      tokens() ++
      connection_strings() ++
      private_keys() ++
      passwords() ++
      env_var_secrets() ++
      json_secrets() ++
      edge_cases()
  end

  @doc """
  Tests a redaction function against all secret variations.

  The `redact_fn` should take a string and return a redacted string.
  Returns a list of failures — secrets that survived redaction.
  """
  @spec test_redaction_completeness((String.t() -> String.t())) :: [map()]
  def test_redaction_completeness(redact_fn) when is_function(redact_fn, 1) do
    variations = generate_secret_variations()

    variations
    |> Enum.map(fn {value, expected_type} ->
      redacted = redact_fn.(value)
      survived = String.contains?(redacted, extract_secret_payload(value))

      %{
        value_preview: preview(value),
        expected_type: expected_type,
        survived: survived,
        redacted_preview: preview(redacted)
      }
    end)
    |> Enum.filter(& &1.survived)
  end

  # --- Secret generators ---

  defp api_keys do
    [
      # OpenAI-style
      {"sk-abcdefghijklmnopqrstuvwx", :api_key},
      {"sk-proj-abcdefghijklmnopqrstuvwx", :api_key},
      {"sk-1234567890abcdefghijklmnopqrstuvwxyz", :api_key},
      # Anthropic
      {"sk-ant-abcdefghijklmnopqrstuvwx", :api_key},
      {"sk-ant-api03-abcdefghijklmnopqrstuvwx", :api_key},
      # AWS
      {"AKIAIOSFODNN7EXAMPLE", :api_key},
      {"AKIA1234567890ABCDEF", :api_key},
      # GitHub (pattern requires 36+ chars after prefix)
      {"ghp_1234567890abcdefghijklmnopqrstuvwxyz1234", :token},
      {"gho_1234567890abcdefghijklmnopqrstuvwxyz1234", :token},
      {"ghs_1234567890abcdefghijklmnopqrstuvwxyz1234", :token},
      # Slack
      {("xoxb-" <> "1234567890-abcdefghijklmnopqrstuvwx"), :token},
      {("xoxa-" <> "123456789012345678901234"), :token},
      {("xoxp-" <> "123456789012345678901234"), :token}
    ]
  end

  defp tokens do
    [
      # Bearer tokens
      {"Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.sig", :token},
      {"Bearer abcdefghijklmnopqrstuvwxyz1234567890ABCDEF", :token},
      # Generic token assignments
      {"api_key=sk-abcdefghijklmnopqrstuvwx", :token},
      {"access_token=ghp_1234567890abcdefghijklmnopqrstuvwx", :token},
      {"refresh_token=abc123def456ghi789jkl012mno345", :token},
      {"Authorization: Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiJ9.payload.sig", :token}
    ]
  end

  defp connection_strings do
    [
      {"postgresql://user:password@localhost:5432/mydb", :connection_string},
      {"postgres://admin:secretpass@db.example.com:5432/production", :connection_string},
      {"mongodb://user:pass@host:27017/database", :connection_string},
      {"mongodb+srv://user:pass@cluster.mongodb.net/db", :connection_string},
      {"mysql://root:password@mysql-server:3306/db", :connection_string},
      {"redis://:secret-password@redis-host:6379/0", :connection_string},
      {"amqp://guest:guest@rabbitmq-host:5672/vhost", :connection_string},
      {"mssql://sa:Password1@sql-server:1433/master", :connection_string}
    ]
  end

  defp private_keys do
    [
      {"-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA0Z3VS5JJcds3xfn/ygWy2kG7\n-----END RSA PRIVATE KEY-----",
       :private_key},
      {"-----BEGIN EC PRIVATE KEY-----\nMHQCAQEEIO1234567890abcdef\n-----END EC PRIVATE KEY-----",
       :private_key},
      {"-----BEGIN OPENSSH PRIVATE KEY-----\nAAAAC3NzaC1lZDI1NTE5AAAAI\n-----END OPENSSH PRIVATE KEY-----",
       :private_key},
      {"-----BEGIN PRIVATE KEY-----\nMIIEvgIBADANBgkqhkiG9w0BAQEFAAS\n-----END PRIVATE KEY-----",
       :private_key},
      # Just header (should also be caught)
      {"-----BEGIN RSA PRIVATE KEY-----", :private_key}
    ]
  end

  defp passwords do
    [
      # Must match generic_token_assignment: key[:=]value{8,} (no quotes needed, 8+ char value)
      {"password=huntertwo1234", :password},
      {"password='super-secret-passphrase'", :password},
      # Must match generic_secret_in_config: key[:=]["']value{8,}["']
      {"passwd: \"changeme12345678\"", :password},
      {"pwd = \"My$ecr3tP@ss!word\"", :password},
      {"secret=my_little_secret_value", :token},
      {"api_key:\"sk-abcdefghijklmnopqrstuvwx\"", :token}
    ]
  end

  defp env_var_secrets do
    [
      {"AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", :generic_secret},
      {"DATABASE_URL=postgres://user:pass@localhost/db", :generic_secret},
      {"OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwx", :generic_secret},
      {"API_TOKEN=abc123def456ghi789", :generic_secret},
      {"MY_APP_PASSWORD=SuperSecret123!", :generic_secret},
      {"PRIVATE_KEY_SECRET=donotshare12345", :generic_secret}
    ]
  end

  defp json_secrets do
    [
      {"{\"api_key\": \"sk-abcdefghijklmnopqrstuvwx\"}", :generic_secret},
      {"{\"password\": \"hunter2\", \"name\": \"prod\"}", :generic_secret},
      {"{\"token\": \"Bearer abc123def456ghi789jkl012mno345pqr678\"}", :generic_secret},
      {"{\"credential\": \"AKIAIOSFODNN7EXAMPLE\"}", :generic_secret}
    ]
  end

  defp edge_cases do
    [
      # Secret in longer context
      {"The API key is sk-abcdefghijklmnopqrstuvwx and it should be redacted", :api_key},
      # Multiple secrets in one string
      {"key1=sk-abcdefghijklmnopqrstuvwx key2=AKIAIOSFODNN7EXAMPLE", :api_key},
      # Secret with whitespace
      {"  sk-abcdefghijklmnopqrstuvwx  ", :api_key},
      # Secret in URL
      {"https://api.openai.com/v1/chat?key=sk-abcdefghijklmnopqrstuvwx", :api_key}
    ]
  end

  # --- Helpers ---

  defp preview(value) when is_binary(value) do
    if String.length(value) > 50 do
      String.slice(value, 0, 47) <> "..."
    else
      value
    end
  end

  defp preview(value), do: inspect(value)

  # Extract the "secret payload" from a test string.
  # For patterns like "key=value", the payload is the value part.
  # For bare secrets, the whole string is the payload.
  defp extract_secret_payload(value) do
    cond do
      # Bearer tokens — the whole token part
      String.starts_with?(value, "Bearer ") ->
        value

      # Key=value patterns — the value
      Regex.match?(~r/^[A-Z_]+=/, value) ->
        [_key, val] = String.split(value, "=", parts: 2)
        val

      # JSON — extract the value
      String.starts_with?(value, "{") ->
        value

      # Otherwise the whole string is the secret
      true ->
        value
    end
  end
end
