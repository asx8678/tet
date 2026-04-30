defmodule Tet.ToolContractTest do
  use ExUnit.Case, async: true

  alias Tet.Tool.Contract
  alias Tet.Tool.ReadOnlyContracts

  @expected_names ["list", "read", "search", "repo-scan", "git-diff", "ask-user"]
  @schema_keys ["type", "properties", "required", "additional_properties"]
  @output_envelope_fields [
    "ok",
    "correlation",
    "data",
    "error",
    "redactions",
    "truncated",
    "limit_usage"
  ]
  @error_fields ["code", "message", "kind", "retryable", "correlation", "details"]
  @correlation_ids ["session_id", "task_id", "tool_call_id"]
  @redaction_sinks [:provider_context, :event_log, :artifact_store, :display, :log]

  test "catalog exposes the six BD-0020 read-only contracts in stable order" do
    assert ReadOnlyContracts.names() == @expected_names
    assert Tet.Tool.read_only_contract_names() == @expected_names
    assert Enum.map(Tet.Tool.read_only_contracts(), & &1.name) == @expected_names
    assert :ok = ReadOnlyContracts.validate_catalog()
  end

  test "contracts include limits, redaction, correlation, schemas, and stable error shapes" do
    for contract <- ReadOnlyContracts.all() do
      assert %Contract{} = contract
      assert :ok = Contract.validate(contract)
      assert contract.namespace == "native.read_only"
      assert contract.version == "1.0.0"
      assert contract.read_only == true
      assert contract.mutation == :none
      assert contract.approval.required == false
      assert contract.execution.status == :contract_only
      assert contract.execution.mutates_workspace == false
      assert contract.execution.mutates_store == false
      assert contract.execution.executes_code == false
      refute :chat in contract.modes

      assert_schema(contract.input_schema)
      assert_schema(contract.output_schema)
      assert_schema(contract.error_schema)
      assert_required_fields(contract.output_schema, @output_envelope_fields)
      assert_required_fields(contract.error_schema, @error_fields)

      assert Map.keys(contract.limits) |> Enum.sort() == [:bytes, :paths, :results, :timeout_ms]
      assert is_map(contract.limits.paths)
      assert is_map(contract.limits.results)
      assert is_map(contract.limits.bytes)
      assert is_integer(contract.limits.timeout_ms)
      assert contract.limits.timeout_ms > 0

      assert Map.keys(contract.redaction) |> Enum.member?(:class)
      assert Enum.all?(@redaction_sinks, &(&1 in contract.redaction.apply_before))
      assert Enum.any?(contract.redaction.rules, &(&1.name == "central_redactor"))
      assert contract.redaction.preserve_shape == true

      assert contract.correlation.required == @correlation_ids
      assert_required_fields(contract.correlation.schema, @correlation_ids)

      assert Enum.all?(
               [:runtime_context, :output, :error, :event_log],
               &(&1 in contract.correlation.propagation)
             )

      output_properties = contract.output_schema["properties"]
      assert Map.has_key?(output_properties, "correlation")
      assert Map.has_key?(output_properties, "error")

      error_properties = contract.error_schema["properties"]
      assert Map.has_key?(error_properties, "correlation")
      assert "timeout" in error_properties["code"]["enum"]
      assert "validation_failed" in error_properties["code"]["enum"]
    end
  end

  test "ask-user is interactive but still read-only and non-mutating" do
    assert {:ok, ask_user} = ReadOnlyContracts.fetch("ask-user")

    assert ask_user.interactive == true
    assert ask_user.read_only == true
    assert ask_user.mutation == :none
    assert ask_user.execution.effects == [:operator_interaction]
    assert ask_user.limits.paths.max_count == 0
    assert ask_user.limits.results.max_questions == 10
    assert ask_user.limits.timeout_ms == 300_000

    for contract <- ReadOnlyContracts.all() -- [ask_user] do
      assert contract.interactive == false
    end
  end

  test "fetch accepts canonical names, atom ids, and legacy aliases without atom leaks" do
    assert {:ok, git_diff} = Tet.Tool.fetch_read_only_contract(:git_diff)
    assert git_diff.name == "git-diff"

    assert {:ok, search} = ReadOnlyContracts.fetch("grep")
    assert search.name == "search"

    assert {:ok, ask_user} = ReadOnlyContracts.fetch("ask_user_question")
    assert ask_user.name == "ask-user"

    assert {:error, {:unknown_read_only_tool_contract, "delete-file"}} =
             ReadOnlyContracts.fetch(:delete_file)
  end

  test "contract builder rejects missing, unknown, and mutating contracts predictably" do
    assert {:ok, list} = ReadOnlyContracts.fetch("list")
    attrs = Map.from_struct(list)

    assert {:error, {:missing_contract_fields, [:limits]}} =
             attrs
             |> Map.delete(:limits)
             |> Contract.new()

    assert {:error, {:unknown_contract_fields, [:surprise]}} =
             attrs
             |> Map.put(:surprise, true)
             |> Contract.new()

    assert {:error, {:invalid_contract_field, :mutation}} =
             attrs
             |> Map.put(:mutation, :write)
             |> Contract.new()

    assert {:error, {:invalid_contract_correlation, :required_ids}} =
             attrs
             |> put_in([:correlation, :required], ["session_id", "tool_call_id"])
             |> Contract.new()
  end

  test "contracts convert to JSON-friendly maps with stable string keys" do
    assert {:ok, read} = ReadOnlyContracts.fetch(:read)
    map = Contract.to_map(read)

    assert map["name"] == "read"
    assert map["read_only"] == true
    assert map["mutation"] == "none"
    assert map["limits"]["timeout_ms"] == 30_000
    assert map["execution"]["status"] == "contract_only"
    assert map["correlation"]["required"] == @correlation_ids
  end

  defp assert_schema(schema) do
    assert is_map(schema)
    assert Enum.all?(@schema_keys, &Map.has_key?(schema, &1))
    assert schema["type"] == "object"
    assert is_map(schema["properties"])
    assert is_list(schema["required"])
    assert is_boolean(schema["additional_properties"])
  end

  defp assert_required_fields(schema, required_fields) do
    assert_schema(schema)
    assert Enum.all?(required_fields, &(&1 in schema["required"]))
    assert Enum.all?(required_fields, &Map.has_key?(schema["properties"], &1))
  end
end
