defmodule Tet.Tool.Schema do
  @moduledoc false

  @type json_schema :: map()

  @doc false
  @spec limits(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          pos_integer()
        ) :: map()
  def limits(max_paths, max_results, max_read_bytes, max_output_bytes, timeout_ms) do
    %{
      paths: %{max_count: max_paths, max_path_bytes: 4_096, workspace_relative: true},
      results: %{max_count: max_results, truncate_over_limit: true},
      bytes: %{
        max_read_bytes: max_read_bytes,
        max_output_bytes: max_output_bytes,
        max_snippet_bytes: 8_192
      },
      timeout_ms: timeout_ms
    }
  end

  @doc false
  @spec redaction(atom()) :: map()
  def redaction(class) do
    %{
      class: class,
      apply_before: [:provider_context, :event_log, :artifact_store, :display, :log],
      rules: [
        %{name: "central_redactor", module: "Tet.Redactor", function: "redact/1"},
        %{name: "secret_like_keys", action: "redact values for sensitive-looking keys"},
        %{name: "bounded_content", action: "truncate before display/provider/event"}
      ],
      preserve_shape: true
    }
  end

  @doc false
  @spec correlation() :: map()
  def correlation do
    %{
      required: ["session_id", "task_id", "tool_call_id"],
      optional: ["turn_id", "plan_id", "request_id"],
      propagation: [:runtime_context, :output, :error, :event_log],
      schema: correlation_schema()
    }
  end

  @doc false
  @spec execution([atom()]) :: map()
  def execution(effects) do
    %{
      status: :contract_only,
      executor: :future_runtime_read_only_tool_executor,
      effects: effects,
      mutates_workspace: false,
      mutates_store: false,
      executes_code: false,
      remote_eligible: false
    }
  end

  @doc false
  @spec output_schema(binary(), json_schema()) :: json_schema()
  def output_schema(description, data_schema) do
    object_schema(
      description,
      %{
        "ok" => boolean_property("True when data is present and error is null.", false),
        "correlation" => correlation_schema(),
        "data" => data_schema,
        "error" => nullable_object_property("Stable tool error object matching error_schema."),
        "redactions" =>
          array_property("Redaction actions applied before exposure.", redaction_action_schema()),
        "truncated" => boolean_property("True if any output was truncated by limits.", false),
        "limit_usage" => object_property("Counters for paths/results/bytes/timeouts consumed.")
      },
      ["ok", "correlation", "data", "error", "redactions", "truncated", "limit_usage"]
    )
  end

  @doc false
  @spec error_schema([binary()]) :: json_schema()
  def error_schema(error_codes) do
    object_schema(
      "Stable read-only tool error shape.",
      %{
        "code" => enum_property("Stable machine-readable error code.", error_codes),
        "message" => string_property("Redacted operator-facing error message."),
        "kind" =>
          enum_property("Error class for policy, retry, and rendering.", [
            "invalid_input",
            "policy_denial",
            "not_found",
            "permission",
            "timeout",
            "unavailable",
            "cancelled",
            "internal"
          ]),
        "retryable" => boolean_property("True only when retrying could safely succeed.", false),
        "correlation" => correlation_schema(),
        "details" => object_property("Redacted structured diagnostics.")
      },
      ["code", "message", "kind", "retryable", "correlation", "details"]
    )
  end

  @doc false
  @spec correlation_schema() :: json_schema()
  def correlation_schema do
    object_schema(
      "Runtime-supplied task/session/tool-call correlation metadata.",
      %{
        "session_id" => string_property("Durable session id."),
        "task_id" => string_property("Durable task id for policy and audit."),
        "tool_call_id" => string_property("Provider/runtime tool-call id."),
        "turn_id" => string_property("Optional assistant turn id."),
        "plan_id" => string_property("Optional plan id for plan-mode gates."),
        "request_id" => string_property("Optional external request id.")
      },
      ["session_id", "task_id", "tool_call_id"]
    )
  end

  @doc false
  @spec summary_schema([binary()]) :: json_schema()
  def summary_schema(counter_names) do
    properties =
      counter_names
      |> Map.new(fn name -> {name, integer_property("#{name} counter.", 0)} end)
      |> Map.put(
        "truncated",
        boolean_property("True if summary is incomplete due to limits.", false)
      )

    object_schema("Bounded result summary.", properties, counter_names ++ ["truncated"])
  end

  @doc false
  @spec object_schema(binary(), map(), [binary()]) :: json_schema()
  def object_schema(description, properties, required) do
    %{
      "type" => "object",
      "description" => description,
      "properties" => properties,
      "required" => required,
      "additional_properties" => false
    }
  end

  @doc false
  @spec object_property(binary()) :: json_schema()
  def object_property(description) do
    %{"type" => "object", "description" => description, "additional_properties" => true}
  end

  @doc false
  @spec nullable_object_property(binary()) :: json_schema()
  def nullable_object_property(description) do
    %{"type" => ["object", "null"], "description" => description, "additional_properties" => true}
  end

  @doc false
  @spec string_property(binary()) :: json_schema()
  def string_property(description) do
    %{"type" => "string", "description" => description, "min_length" => 1}
  end

  @doc false
  @spec nullable_string_property(binary()) :: json_schema()
  def nullable_string_property(description) do
    %{"type" => ["string", "null"], "description" => description}
  end

  @doc false
  @spec boolean_property(binary(), boolean()) :: json_schema()
  def boolean_property(description, default) do
    %{"type" => "boolean", "description" => description, "default" => default}
  end

  @doc false
  @spec integer_property(binary(), non_neg_integer()) :: json_schema()
  def integer_property(description, minimum) do
    %{"type" => "integer", "description" => description, "minimum" => minimum}
  end

  @doc false
  @spec integer_property(binary(), non_neg_integer(), non_neg_integer()) :: json_schema()
  def integer_property(description, minimum, maximum) do
    description
    |> integer_property(minimum)
    |> Map.put("maximum", maximum)
  end

  @doc false
  @spec enum_property(binary(), [binary()]) :: json_schema()
  def enum_property(description, values) do
    %{"type" => "string", "description" => description, "enum" => values}
  end

  @doc false
  @spec array_property(binary(), json_schema()) :: json_schema()
  def array_property(description, item_schema) do
    %{"type" => "array", "description" => description, "items" => item_schema}
  end

  defp redaction_action_schema do
    object_schema(
      "One redaction action applied to output.",
      %{
        "rule" => string_property("Redaction rule name."),
        "path" => string_property("JSON path or logical field affected."),
        "replacement" => string_property("Replacement marker, usually [REDACTED].")
      },
      ["rule", "path"]
    )
  end
end
