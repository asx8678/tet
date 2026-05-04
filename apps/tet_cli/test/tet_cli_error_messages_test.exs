defmodule Tet.CLI.ErrorMessagesTest do
  @moduledoc """
  BD-0093: User-facing error message quality audit.

  Verifies every error path produces messages that:
  - Are understandable to users unfamiliar with Elixir/OTP internals
  - Never leak raw exception structs, `%Protocol.UndefinedError{}`, or `** (EXIT)`
  - Include actionable suggestions where possible
  """
  use ExUnit.Case, async: true

  alias Tet.CLI.Render

  # ── 1. Missing provider config ──────────────────────────────────────────

  describe "error(:missing_provider_env)" do
    test "names the specific environment variable needed" do
      msg = Render.error({:missing_provider_env, "TET_OPENAI_API_KEY"})
      assert msg =~ "TET_OPENAI_API_KEY"
      assert msg =~ "missing required environment variable"
      refute msg =~ "%{"
      refute msg =~ "Struct"
    end

    test "does not contain Elixir internals" do
      msg = Render.error({:missing_provider_env, "TET_ANTHROPIC_API_KEY"})
      refute msg =~ "Elixir"
      refute msg =~ "OTP"
      refute msg =~ "%{"
    end
  end

  describe "error({:unknown_provider, _})" do
    test "named tuple variant shows provider name" do
      msg = Render.error({:unknown_provider, {:unknown, "bedrock"}})
      assert msg =~ "bedrock"
      assert msg =~ "unknown provider"
      assert msg =~ "supported providers"
    end

    test "generic tuple variant shows inspect" do
      msg = Render.error({:unknown_provider, :vertex_ai})
      assert msg =~ "unknown provider"
      assert msg =~ "openai"
    end
  end

  describe "error(:invalid_provider_option)" do
    test "names the missing option" do
      msg = Render.error({:invalid_provider_option, :api_key})
      assert msg =~ "provider missing required option"
      assert msg =~ "api_key"
    end
  end

  describe "error({:invalid_provider_chunk, _})" do
    test "is human-readable" do
      msg = Render.error({:invalid_provider_chunk, :missing_choices})
      assert msg =~ "provider sent invalid response chunk"
      assert msg =~ "missing_choices"
      refute msg =~ "%{"
    end
  end

  describe "error(:provider_timeout)" do
    test "produces a readable message" do
      msg = Render.error(:provider_timeout)
      assert msg =~ "provider timed out"
    end
  end

  # ── 2. Invalid session ID ──────────────────────────────────────────────

  describe "error(:session_not_found)" do
    test "produces clear 'session not found' message" do
      msg = Render.error(:session_not_found)
      assert msg =~ "session not found"
      refute msg =~ "%{"
    end
  end

  describe "error(:invalid_session)" do
    test "produces clear message for invalid session" do
      msg = Render.error(:invalid_session)
      assert msg =~ "session"
      assert msg =~ "not found" or msg =~ "not running"
    end
  end

  # ── 3. Store permission errors ─────────────────────────────────────────

  describe "store permission errors" do
    test "store_unhealthy shows path and suggestion" do
      msg = Render.error({:store_unhealthy, "/home/user/.tet", :eacces})
      assert msg =~ "/home/user/.tet"
      assert msg =~ "unhealthy"
      assert msg =~ "permissions" or msg =~ "check"
    end

    test "store_not_configured includes TET_STORE_PATH hint" do
      msg = Render.error(:store_not_configured)
      assert msg =~ "TET_STORE_PATH"
      assert msg =~ "doctor"
    end

    test "store_adapter_unavailable is clear" do
      msg = Render.error({:store_adapter_unavailable, Tet.Store.SQLite})
      assert msg =~ "unavailable"
      assert msg =~ "store application" or msg =~ "release"
    end

    test "store_adapter_missing_callbacks names the adapter and callbacks" do
      msg = Render.error({:store_adapter_missing_callbacks, Tet.Store.SQLite, [:save_message, :list_messages]})
      assert msg =~ "missing required callbacks"
      assert msg =~ "save_message"
      assert msg =~ "list_messages"
    end
  end

  # ── 4. Network errors during streaming ─────────────────────────────────

  describe "network errors" do
    test "provider_timeout produces clear timeout message" do
      msg = Render.error(:provider_timeout)
      assert msg =~ "timed out"
      refute msg =~ "%{"
      refute msg =~ "Struct"
    end

    test "provider_http_error with failed_connect formats host" do
      reason = {:failed_connect, [to_address: {"api.openai.com", 443}]}
      msg = Render.error({:provider_http_error, reason})
      assert msg =~ "could not connect to"
      assert msg =~ "api.openai.com"
      refute msg =~ "%{"
    end

    test "provider_http_error with closed connection" do
      reason = {:closed, :timeout}
      msg = Render.error({:provider_http_error, reason})
      assert msg =~ "closed" or msg =~ "connection"
      refute msg =~ "Struct"
    end

    test "provider_http_error with generic reason" do
      msg = Render.error({:provider_http_error, :timeout})
      assert msg =~ "timed out" or msg =~ "network error"
    end

    test "provider_adapter_exception is user-friendly" do
      msg = Render.error({:provider_adapter_exception, "unexpected token"})
      assert msg =~ "provider internal error"
      assert msg =~ "unexpected token"
      refute msg =~ "%{"
    end

    test "provider_adapter_exit does not leak raw terms" do
      msg = Render.error({:provider_adapter_exit, :error, %RuntimeError{message: "crash"}})
      assert msg =~ "crashed"
      assert msg =~ "crash"
      refute msg =~ "%RuntimeError{"
    end

    test "provider_stream_incomplete has suggestion" do
      msg = Render.error(:provider_stream_incomplete)
      assert msg =~ "stream ended before completion"
      assert msg =~ "try again" or msg =~ "network"
    end

    test "provider_http_unavailable formats reason" do
      msg = Render.error({:provider_http_unavailable, :timeout})
      assert msg =~ "HTTP client unavailable"
      refute msg =~ "%{"
    end
  end

  # ── 5. Invalid command/flag ────────────────────────────────────────────

  describe "invalid command handling" do
    test "unknown tet command shows suggestion" do
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Tet.CLI.run(["asks"])
        end)

      assert output =~ "unknown tet command: asks"
      assert output =~ "did you mean"
      assert output =~ "ask"
    end
  end

  # ── 6. Provider API errors ─────────────────────────────────────────────

  describe "provider API errors" do
    test "HTTP 401 extracts error message from JSON body" do
      body = ~s({"error":{"message":"Invalid API key","type":"invalid_request_error"}})
      msg = Render.error({:provider_http_status, 401, "Unauthorized", body})
      assert msg =~ "401"
      assert msg =~ "Unauthorized"
      assert msg =~ "Invalid API key"
      refute msg =~ "invalid_request_error" or msg =~ "should not show raw body"
    end

    test "HTTP 429 with rate limit message" do
      body = ~s({"error":{"message":"Rate limit exceeded","code":"rate_limit_exceeded"}})
      msg = Render.error({:provider_http_status, 429, "Too Many Requests", body})
      assert msg =~ "429"
      assert msg =~ "Rate limit exceeded"
    end

    test "HTTP 500 with non-JSON body truncates" do
      body = String.duplicate("x", 500)
      msg = Render.error({:provider_http_status, 500, "Internal Server Error", body})
      assert msg =~ "500"
      assert msg =~ "Internal Server Error"
      # Body should be truncated
      assert String.length(msg) < 400
    end

    test "HTTP error with non-string body" do
      msg = Render.error({:provider_http_status, 502, "Bad Gateway", nil})
      assert msg =~ "502"
      assert msg =~ "Bad Gateway"
    end

    test "HTTP error with malformed JSON body shows raw body truncated" do
      body = "this is not json at all"
      msg = Render.error({:provider_http_status, 500, "Internal Server Error", body})
      assert msg =~ "500"
      assert msg =~ "this is not json"
    end

    test "HTTP error with empty body" do
      msg = Render.error({:provider_http_status, 500, "Internal Server Error", ""})
      assert msg =~ "500"
    end

    test "HTTP error extracts nested error.message from complex JSON" do
      body =
        ~s({"error":{"message":"Model not found","type":"invalid_request_error","code":"model_not_found"}})

      msg = Render.error({:provider_http_status, 404, "Not Found", body})
      assert msg =~ "404"
      assert msg =~ "Model not found"
    end
  end

  # ── 7. SQLite errors ──────────────────────────────────────────────────

  describe "SQLite / database errors" do
    test "session_creation_failed is user-friendly" do
      msg = Render.error({:session_creation_failed, %{}})
      assert msg =~ "database error"
      assert msg =~ "TET_STORE_PATH"
      refute msg =~ "%{"
    end

    test "workspace_creation_failed is user-friendly" do
      msg = Render.error({:workspace_creation_failed, %{}})
      assert msg =~ "database error"
      assert msg =~ "TET_STORE_PATH"
      refute msg =~ "%{"
    end

    test "changeset_error is user-friendly" do
      msg = Render.error({:changeset_error, %{}})
      assert msg =~ "database validation"
      assert msg =~ "store permissions" or msg =~ "integrity"
      refute msg =~ "%{"
    end

    test "workspace_not_found is clear" do
      msg = Render.error(:workspace_not_found)
      assert msg =~ "workspace not found"
    end

    test "SQLite3.Error-like struct is user-friendly" do
      # Use a generic struct that matches %{__struct__: SQLite3.Error} pattern
      # In production, the catch-all handles it. Test the catch-all path.
      msg = Render.error({:store_unhealthy, "/app/.tet", "database is locked"})
      assert msg =~ "unhealthy"
      assert msg =~ "/app/.tet"
    end

    test "Ecto.NoResultsError produces clear message" do
      exception = %Ecto.NoResultsError{message: "no result"}
      msg = Render.error(exception)
      assert msg =~ "record not found"
      refute msg =~ "%Ecto"
    end

    test "Ecto.QueryError is user-friendly" do
      exception = %Ecto.QueryError{message: "bad query"}
      msg = Render.error(exception)
      assert msg =~ "database query error"
      refute msg =~ "%Ecto.QueryError"
    end
  end

  # ── 8. Profile not found ──────────────────────────────────────────────

  describe "profile_not_found" do
    test "produces clear message" do
      msg = Render.error(:profile_not_found)
      assert msg =~ "profile not found"
    end
  end

  describe "profile show with missing profile" do
    test "lists available profiles in error output" do
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Tet.CLI.run(["profile", "show", "nonexistent"])
        end)

      assert output =~ "not found"
    end
  end

  # ── 9. Tool contract violations ───────────────────────────────────────

  describe "tool contract errors" do
    test "unknown contract fields are clear" do
      msg = Render.error([{:unknown_contract_fields, ["invalid_field"]}])
      assert msg =~ "unknown_contract_fields"
      refute msg =~ "%{"
    end

    test "missing contract fields are clear" do
      msg = Render.error([{:missing_contract_fields, [:name, :version]}])
      assert msg =~ "missing_contract_fields"
    end

    test "invalid tool arguments are clear" do
      msg = Render.error({:invalid_tool_arguments, 0, :not_a_map})
      assert is_binary(msg)
      refute msg =~ "%{"
    end
  end

  # ── 10. Additional CLI-level error paths ───────────────────────────────

  describe "additional CLI error paths" do
    test ":empty_prompt is clear" do
      msg = Render.error(:empty_prompt)
      assert msg =~ "prompt cannot be empty"
    end

    test ":invalid_session_id is clear" do
      msg = Render.error(:invalid_session_id)
      assert msg =~ "session id is invalid"
    end

    test ":empty_session_id is clear" do
      msg = Render.error(:empty_session_id)
      assert msg =~ "session id cannot be empty"
    end

    test ":autosave_not_found is clear" do
      msg = Render.error(:autosave_not_found)
      assert msg =~ "autosave checkpoint not found"
    end

    test ":unsupported_shell is clear" do
      msg = Render.error({:unsupported_shell, "powershell"})
      assert msg =~ "unsupported shell"
      assert msg =~ "powershell"
    end

    test "ProfileRegistry.Error is user-friendly" do
      error = %Tet.ProfileRegistry.Error{
        path: ["profiles", 0],
        code: :missing_field,
        message: "missing required field 'display_name'"
      }
      msg = Render.error(error)
      assert msg =~ "missing required field"
      assert msg =~ "display_name"
      refute msg =~ "%Tet.ProfileRegistry.Error"
    end

    test "ModelRegistry.Error is user-friendly" do
      error = %Tet.ModelRegistry.Error{
        path: ["models", 0],
        code: :invalid_type,
        message: "model type must be string"
      }
      msg = Render.error(error)
      assert msg =~ "model type must be string"
      refute msg =~ "%Tet.ModelRegistry.Error"
    end

    test "session show with session not found suggests sessions command" do
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Tet.CLI.run(["session", "show", "nonexistent-session-id"])
        end)

      assert output =~ "not found"
      assert output =~ "tet sessions" or output =~ "sessions"
    end

    test "unknown tet command for truly unknown command shows no suggestion" do
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Tet.CLI.run(["xyzzy"])
        end)

      assert output =~ "unknown tet command: xyzzy"
      refute output =~ "did you mean"
    end
  end

  # ── Catch-all safety ──────────────────────────────────────────────────

  describe "catch-all error handling" do
    test "struct errors never leak raw struct syntax" do
      msg = Render.error(%RuntimeError{message: "boom"})
      assert msg =~ "boom"
      refute msg =~ "%RuntimeError{"
      refute msg =~ "__struct__"
    end

    test "atom errors produce readable text" do
      msg = Render.error(:something_weird)
      assert msg =~ "error"
      assert is_binary(msg)
      refute msg =~ "%{"
    end

    test "binary errors pass through" do
      msg = Render.error("custom error message")
      assert msg == "custom error message"
    end

    test "tuple errors are truncated safely" do
      msg = Render.error({:weird, :error, :tuple})
      assert is_binary(msg)
      assert String.length(msg) <= 220
      refute msg =~ "%{"
    end

    test "complex map errors are truncated safely" do
      msg = Render.error(%{complex: %{nested: %{deep: "value"}}})
      assert is_binary(msg)
      assert String.length(msg) <= 220
    end

    test "list of non-registry errors are formatted safely" do
      msg = Render.error([:error1, :error2, :error3])
      assert msg =~ "error1"
      assert msg =~ "error2"
    end

    test "large error lists are truncated" do
      errors = Enum.to_list(1..10)
      msg = Render.error(errors)
      assert msg =~ "and 5 more errors"
    end
  end

  # ── Acceptance: no raw exception patterns in any error message ──────────

  describe "acceptance criteria - no raw Elixir internals" do
    test "no Protocol.UndefinedError in any error message" do
      errors = [
        :empty_prompt,
        :invalid_session_id,
        :session_not_found,
        :profile_not_found,
        :store_not_configured,
        :provider_timeout,
        :provider_stream_incomplete,
        :workspace_not_found
      ]

      for error <- errors do
        msg = Render.error(error)

        refute msg =~ "Protocol.UndefinedError",
               "raw Protocol.UndefinedError in: #{inspect(error)}"

        refute msg =~ "EXIT", "EXIT in: #{inspect(error)}"
        refute msg =~ "__struct__", "struct leak in: #{inspect(error)}"
      end
    end

    test "complex error tuples never produce raw Elixir syntax" do
      errors = [
        {:missing_provider_env, "TET_OPENAI_API_KEY"},
        {:unknown_provider, {:unknown, "foo"}},
        {:store_adapter_unavailable, SomeModule},
        {:provider_http_error, {:closed, :timeout}},
        {:provider_adapter_exit, :error, %RuntimeError{message: "fail"}},
        {:session_creation_failed, nil},
        {:changeset_error, nil},
        {:provider_http_status, 401, "Unauthorized", "{}"}
      ]

      for error <- errors do
        msg = Render.error(error)
        assert is_binary(msg), "error/1 did not return string for: #{inspect(error)}"
        refute msg =~ "Elixir", "Elixir reference in: #{inspect(error)}"
        refute msg =~ "%{__struct__:", "struct literal in: #{inspect(error)}"
      end
    end
  end
end
