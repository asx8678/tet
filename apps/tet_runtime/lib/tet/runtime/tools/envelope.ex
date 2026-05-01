defmodule Tet.Runtime.Tools.Envelope do
  @moduledoc """
  Shared BD-0020 envelope builders for read-only tool results.

  Every tool response must conform to the standard shape:
    - `ok` — boolean
    - `correlation` — nil (future: propagated correlation map)
    - `data` — result payload or nil on error
    - `error` — nil on success, denial map on error
    - `redactions` — list (always [] in this layer)
    - `truncated` — boolean
    - `limit_usage` — map with counters

  Success includes `error: nil` and `redactions: []`.
  Errors include `data: nil` and `redactions: []`.
  """

  @type t :: %{
          required(:ok) => boolean(),
          required(:correlation) => term(),
          required(:data) => term(),
          required(:error) => term(),
          required(:redactions) => list(),
          required(:truncated) => boolean(),
          required(:limit_usage) => map()
        }

  @doc """
  Builds a standard success envelope.

  ## Options
    - `:limit_usage` — map with `paths`, `results`/`bytes`/`lines` usage counters
    - `:truncated` — boolean, default false
  """
  @spec success(map(), keyword()) :: t()
  def success(data, opts \\ []) do
    %{
      ok: true,
      correlation: nil,
      data: data,
      error: nil,
      redactions: [],
      truncated: Keyword.get(opts, :truncated, false),
      limit_usage: Keyword.get(opts, :limit_usage, %{})
    }
  end

  @doc """
  Builds a standard error envelope from a denial map.

  ## Options
    - `:limit_usage` — map with `paths`, `results`/`bytes`/`lines` usage counters
  """
  @spec error(map(), keyword()) :: t()
  def error(denial, opts \\ []) do
    %{
      ok: false,
      correlation: nil,
      data: nil,
      error: denial,
      redactions: [],
      truncated: false,
      limit_usage: Keyword.get(opts, :limit_usage, %{paths: %{used: 0, max: 0}})
    }
  end

  @doc """
  Builds a standard unknown-tool error envelope.
  """
  @spec unknown_tool(String.t()) :: t()
  def unknown_tool(tool_name) do
    denial = %{
      code: "tool_unavailable",
      message: "Unknown tool: #{tool_name}",
      kind: "unavailable",
      retryable: false,
      details: %{}
    }

    error(denial, limit_usage: default_limit_usage())
  end

  @doc """
  Returns a zeroed default limit_usage map for consistent shape.
  """
  @spec default_limit_usage() :: map()
  def default_limit_usage do
    %{
      paths: %{used: 0, max: 0},
      results: %{used: 0, max: 0}
    }
  end

  @doc """
  Asserts a result map has all required BD-0020 envelope keys.
  """
  @spec assert_envelope_shape(map()) :: :ok | {:error, [atom()]}
  def assert_envelope_shape(result) when is_map(result) do
    required_keys = [:ok, :correlation, :data, :error, :redactions, :truncated, :limit_usage]
    missing = Enum.reject(required_keys, &Map.has_key?(result, &1))

    if missing == [] do
      :ok
    else
      {:error, missing}
    end
  end
end
