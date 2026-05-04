defmodule Tet.CLI.ErrorFormatter do
  @moduledoc """
  Shared error formatting helpers for user-facing messages.

  Every public function returns a human-readable String.t() that a user
  unfamiliar with Elixir/OTP internals can understand and act on. Raw
  exception structs, Erlang httpc error tuples, and Ecto changesets are
  never leaked — they are translated into actionable messages.
  """

  @doc "Extracts a user-friendly error message from a provider HTTP response body."
  @spec truncate_provider_body(term()) :: String.t()
  def truncate_provider_body(body) when is_binary(body) do
    extracted = extract_provider_error_message(body)
    truncated = String.slice(extracted, 0, 200)

    if String.length(extracted) > 200 do
      truncated <> "..."
    else
      truncated
    end
  end

  def truncate_provider_body(body), do: inspect_value(body)

  @doc "Formats an httpc/HTTP client error reason into a readable string."
  @spec format_httpc_reason(term()) :: String.t()
  def format_httpc_reason({:failed_connect, details}) when is_list(details) do
    host = find_connect_target(details)
    "could not connect to #{host}"
  end

  def format_httpc_reason({:closed, _}), do: "connection was closed by the remote server"
  def format_httpc_reason(:timeout), do: "connection timed out"
  def format_httpc_reason(:einval), do: "invalid connection parameters"
  def format_httpc_reason({:shutdown, _reason}), do: "connection was shut down"
  def format_httpc_reason(reason), do: inspect_value(reason)

  @doc "Formats a provider adapter exit value, extracting exception messages when possible."
  @spec format_provider_exit_value(term()) :: String.t()
  def format_provider_exit_value(%{__struct__: _} = exception) do
    Exception.message(exception)
  rescue
    _ -> inspect_value(exception)
  end

  def format_provider_exit_value({exception}) when is_struct(exception) do
    Exception.message(exception)
  rescue
    _ -> inspect_value(exception)
  end

  def format_provider_exit_value(value) do
    case value do
      %{__struct__: _} = exception -> Exception.message(exception)
      {exception} when is_struct(exception) -> Exception.message(exception)
      :normal -> "process exited normally"
      :shutdown -> "process was shut down"
      _ -> inspect_value(value)
    end
  rescue
    _ -> inspect_value(value)
  end

  @doc "Formats a list of error reasons into a human-readable string."
  @spec format_error_list([term()]) :: String.t()
  def format_error_list([]), do: "no errors"

  def format_error_list(errors) do
    formatted =
      errors
      |> Enum.take(5)
      |> Enum.map(&inspect_value/1)
      |> Enum.join("; ")

    if length(errors) > 5 do
      formatted <> "; and #{length(errors) - 5} more errors"
    else
      formatted
    end
  end

  @doc "Formats a reason atom into a readable error message."
  @spec format_atom_reason(atom()) :: String.t()
  def format_atom_reason(:unknown), do: "unknown error"
  def format_atom_reason(:cancelled), do: "operation was cancelled"
  def format_atom_reason(:timeout), do: "operation timed out"
  def format_atom_reason(:not_found), do: "resource not found"
  def format_atom_reason(:permission_denied), do: "permission denied"
  def format_atom_reason(:internal), do: "internal error"
  def format_atom_reason(:unavailable), do: "service unavailable"
  def format_atom_reason(atom), do: "error: #{Atom.to_string(atom)}"

  @doc "Safely inspects a value, truncating to 200 characters."
  @spec inspect_value(term()) :: String.t()
  def inspect_value(value) do
    inspected = inspect(value)
    String.slice(inspected, 0, 200)
  rescue
    _ -> "[could not format error details]"
  end

  @doc "Extracts the struct module name for display purposes."
  @spec inspect_struct_name(map()) :: String.t()
  def inspect_struct_name(%{__struct__: module}) do
    module |> Module.split() |> List.last()
  end

  def inspect_struct_name(_), do: "unknown"

  # ── Private ──────────────────────────────────────────────────────────

  defp extract_provider_error_message(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"message" => message}}} when is_binary(message) ->
        message

      {:ok, %{"error" => %{"message" => message, "type" => type}}} when is_binary(message) ->
        "[#{type}] #{message}"

      {:ok, %{"error" => %{"code" => code, "message" => message}}} when is_binary(message) ->
        "[#{code}] #{message}"

      {:ok, %{"error" => message}} when is_binary(message) ->
        message

      {:ok, _} ->
        body

      _ ->
        body
    end
  end

  defp find_connect_target(details) do
    case Keyword.get(details, :to_address) do
      {host, port} ->
        "#{host}:#{port}"

      _ ->
        case Keyword.get(details, :host) do
          host when is_binary(host) -> host
          _ -> "the provider server"
        end
    end
  rescue
    _ -> "the provider server"
  end
end
