defmodule Tet.Runtime.Tools.Executor do
  @moduledoc """
  Dispatches provider tool calls to runtime tool implementations.

  Takes a completed tool call (name, arguments, id) from the provider,
  resolves it to a runtime tool module, executes it, and returns the
  result formatted for provider consumption — a JSON-encoded string
  inside an `{:ok, %{tool_call_id, content}}` tuple.

  ## Contract

  Every call returns `{:ok, %{tool_call_id: id, content: json_string}}`.

  Errors are never raised — they are captured as error envelopes and
  JSON-encoded just like success results. The provider reads the
  envelope's `ok` field to distinguish success from failure.

  ## Pipeline

      1. Resolve tool name → module
      2. Execute module.run(args, opts) inside try/rescue
      3. Optionally persist a ToolRun record via the store
      4. Redact secrets with Outbound.redact_for_event/1
      5. Prepare structs/tuples for JSON serialization
      6. Encode to JSON string

  ## Usage

      {:ok, result} = Executor.execute(%{
        name: "read",
        id: "call_abc",
        arguments: %{"path" => "file.ex"},
        index: 0
      }, workspace_root: "/workspace")

  String-keyed maps are also accepted:

      {:ok, result} = Executor.execute(%{
        "name" => "read",
        "id" => "call_abc",
        "arguments" => %{"path" => "file.ex"}
      }, workspace_root: "/workspace")
  """

  alias Tet.Runtime.Tools.{Envelope, Read, List, Search, Patch}
  alias Tet.Redactor.Outbound

  @tool_modules %{
    "read" => Read,
    "list" => List,
    "search" => Search,
    "patch" => Patch
  }

  @read_only_tools MapSet.new(["read", "list", "search"])

  # ── Public API ─────────────────────────────────────────────────────

  @doc """
  Executes a single tool call from the provider.

  ## Options

    - `:workspace_root` — required, absolute workspace path
    - `:session_id` — for ToolRun correlation
    - `:task_id` — for ToolRun correlation (optional)
    - `:store` — store adapter module (optional, for persisting tool runs)
    - `:store_opts` — store options (optional)
  """
  @spec execute(map(), keyword()) :: {:ok, %{tool_call_id: String.t(), content: String.t()}}
  def execute(%{name: name, id: tool_call_id, arguments: arguments}, opts) do
    started_at = DateTime.utc_now()

    opts_with_call_id = Keyword.put(opts, :tool_call_id, tool_call_id)
    result = do_execute(name, arguments, opts_with_call_id)

    finished_at = DateTime.utc_now()

    maybe_persist_tool_run(name, arguments, result, tool_call_id, started_at, finished_at, opts)

    content = result |> redact_result() |> prepare_for_json() |> encode_result()

    {:ok, %{tool_call_id: tool_call_id, content: content}}
  end

  def execute(%{"name" => name, "id" => id, "arguments" => args}, opts) do
    execute(%{name: name, id: id, arguments: args, index: 0}, opts)
  end

  @doc "Returns the list of known tool names."
  @spec known_tools() :: [String.t()]
  def known_tools, do: Map.keys(@tool_modules)

  @doc "Returns true if the tool name is registered."
  @spec known_tool?(String.t()) :: boolean()
  def known_tool?(name), do: Map.has_key?(@tool_modules, name)

  @doc "Returns true if the tool is read-only (no side effects)."
  @spec read_only?(String.t()) :: boolean()
  def read_only?(name), do: MapSet.member?(@read_only_tools, name)

  # ── Private ─────────────────────────────────────────────────────────

  defp do_execute(name, arguments, opts) do
    case Map.fetch(@tool_modules, name) do
      {:ok, module} ->
        try do
          module.run(arguments, opts)
        rescue
          exception ->
            Envelope.error(%{
              code: "internal_error",
              message: "Tool #{name} raised: #{Exception.message(exception)}",
              kind: "internal",
              retryable: false
            })
        end

      :error ->
        Envelope.unknown_tool(name)
    end
  end

  # Redact secrets from tool output before it reaches the provider.
  # Outbound layer (BD-0068): strips secrets with fingerprints disabled.
  defp redact_result(result) do
    Outbound.redact_for_event(result)
  rescue
    _ -> result
  end

  # Recursively convert structs to plain maps (dropping __struct__)
  # and tuples to lists so that :json.encode can handle the data.
  defp prepare_for_json(%{__struct__: _} = struct) do
    struct |> Map.from_struct() |> prepare_for_json()
  end

  defp prepare_for_json(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, prepare_for_json(v)} end)
  end

  defp prepare_for_json(list) when is_list(list) do
    Enum.map(list, &prepare_for_json/1)
  end

  defp prepare_for_json(value) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.map(&prepare_for_json/1)
  end

  defp prepare_for_json(value), do: value

  defp encode_result(result) do
    result
    |> :json.encode()
    |> IO.iodata_to_binary()
  rescue
    _ ->
      ~s({"ok":false,"error":{"code":"serialization_error","message":"Failed to encode tool result"}})
  end

  defp maybe_persist_tool_run(
         name,
         arguments,
         result,
         tool_call_id,
         started_at,
         finished_at,
         opts
       ) do
    store = Keyword.get(opts, :store)

    if store do
      status = if result[:ok], do: :success, else: :error

      attrs = %{
        id: tool_call_id,
        session_id: Keyword.get(opts, :session_id, "unknown"),
        tool_name: name,
        read_or_write: if(read_only?(name), do: :read, else: :write),
        status: status,
        args: arguments,
        started_at: started_at,
        finished_at: finished_at
      }

      store.record_tool_run(attrs)
    end
  rescue
    _ -> :ok
  end
end
