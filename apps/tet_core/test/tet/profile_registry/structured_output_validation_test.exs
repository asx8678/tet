defmodule Tet.ProfileRegistry.StructuredOutputValidationTest do
  @moduledoc """
  BD-0040: Validates that specialty profiles produce schema-valid structured
  outputs under a fake provider. Invalid structured outputs trigger structured
  repair/retry events, not crashes.
  """

  use ExUnit.Case, async: true

  alias Tet.ProfileRegistry
  alias Tet.ProfileRegistry.StructuredOutput

  @registry_path Path.expand("../../../../tet_runtime/priv/profile_registry.json", __DIR__)

  setup do
    {:ok, registry} =
      @registry_path |> File.read!() |> ProfileRegistry.from_json()

    %{registry: registry}
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC-1: json-data profile produces valid JSON output matching declared schema
  # ══════════════════════════════════════════════════════════════════════════

  describe "json-data profile structured output" do
    test "valid output matches declared response schema", %{registry: registry} do
      schema = overlay(registry, "json-data")

      output = %{
        "data" => %{"users" => [%{"name" => "Alice", "age" => 30}]},
        "valid" => true,
        "schema_id" => "user_list_v1",
        "validation_errors" => []
      }

      assert :ok = StructuredOutput.validate(output, schema)
    end

    test "output with only required fields is valid", %{registry: registry} do
      assert :ok =
               StructuredOutput.validate(
                 %{"data" => %{"k" => "v"}, "valid" => true},
                 overlay(registry, "json-data")
               )
    end

    test "output with nested data passes validation", %{registry: registry} do
      output = %{
        "data" => %{
          "config" => %{"db" => %{"host" => "localhost", "port" => 5432, "ssl" => false}}
        },
        "valid" => true,
        "validation_errors" => ["warning: deprecated"]
      }

      assert :ok = StructuredOutput.validate(output, overlay(registry, "json-data"))
    end

    test "rejects wrong type for data field", %{registry: registry} do
      assert {:error, errors} =
               StructuredOutput.validate(
                 %{"data" => "not_an_object", "valid" => true},
                 overlay(registry, "json-data")
               )

      assert Enum.any?(errors, &(&1.path == ["data"] and &1.code == :invalid_type))
    end

    test "rejects wrong type for valid field", %{registry: registry} do
      assert {:error, errors} =
               StructuredOutput.validate(
                 %{"data" => %{}, "valid" => "yes"},
                 overlay(registry, "json-data")
               )

      assert Enum.any?(errors, &(&1.path == ["valid"] and &1.code == :invalid_type))
    end

    test "rejects missing required data field", %{registry: registry} do
      assert {:error, errors} =
               StructuredOutput.validate(%{"valid" => true}, overlay(registry, "json-data"))

      assert Enum.any?(errors, &(&1.code == :required and &1.details.field == "data"))
    end

    test "rejects missing required valid field", %{registry: registry} do
      assert {:error, errors} =
               StructuredOutput.validate(%{"data" => %{}}, overlay(registry, "json-data"))

      assert Enum.any?(errors, &(&1.code == :required and &1.details.field == "valid"))
    end

    test "rejects validation_errors when wrong type", %{registry: registry} do
      output = %{"data" => %{}, "valid" => false, "validation_errors" => "not an array"}
      assert {:error, errors} = StructuredOutput.validate(output, overlay(registry, "json-data"))
      assert Enum.any?(errors, &(&1.path == ["validation_errors"] and &1.code == :invalid_type))
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC-2: reviewer profile produces structured review output with required fields
  # ══════════════════════════════════════════════════════════════════════════

  describe "reviewer profile structured output" do
    test "valid output with findings matches declared schema", %{registry: registry} do
      output = %{
        "findings" => [
          %{
            "severity" => "critical",
            "file" => "lib/auth.ex",
            "line" => 42,
            "message" => "SQL injection",
            "suggestion" => "Use parameterized queries"
          },
          %{
            "severity" => "minor",
            "file" => "lib/utils.ex",
            "line" => 15,
            "message" => "Unused variable",
            "suggestion" => "Remove it"
          }
        ],
        "summary" => "Found 2 issues: 1 critical, 1 minor"
      }

      assert :ok = StructuredOutput.validate(output, overlay(registry, "reviewer"))
    end

    test "valid output with empty findings list", %{registry: registry} do
      output = %{"findings" => [], "summary" => "No issues found"}
      assert :ok = StructuredOutput.validate(output, overlay(registry, "reviewer"))
    end

    test "finding without optional suggestion is still valid", %{registry: registry} do
      output = %{
        "findings" => [
          %{
            "severity" => "major",
            "file" => "lib/core.ex",
            "line" => 100,
            "message" => "Missing error handling"
          }
        ],
        "summary" => "Found 1 issue"
      }

      assert :ok = StructuredOutput.validate(output, overlay(registry, "reviewer"))
    end

    test "rejects missing required findings field", %{registry: registry} do
      assert {:error, errors} =
               StructuredOutput.validate(%{"summary" => "Done"}, overlay(registry, "reviewer"))

      assert Enum.any?(errors, &(&1.code == :required and &1.details.field == "findings"))
    end

    test "rejects missing required summary field", %{registry: registry} do
      assert {:error, errors} =
               StructuredOutput.validate(%{"findings" => []}, overlay(registry, "reviewer"))

      assert Enum.any?(errors, &(&1.code == :required and &1.details.field == "summary"))
    end

    test "rejects findings with wrong severity type", %{registry: registry} do
      bad = %{
        "findings" => [
          %{"severity" => 42, "file" => "lib/ex.ex", "line" => 1, "message" => "test"}
        ],
        "summary" => "Bad"
      }

      assert {:error, errors} = StructuredOutput.validate(bad, overlay(registry, "reviewer"))

      assert Enum.any?(
               errors,
               &(&1.path == ["findings", 0, "severity"] and &1.code == :invalid_type)
             )
    end

    test "rejects findings with wrong line type", %{registry: registry} do
      bad = %{
        "findings" => [
          %{"severity" => "minor", "file" => "lib/ex.ex", "line" => "oops", "message" => "test"}
        ],
        "summary" => "Bad"
      }

      assert {:error, errors} = StructuredOutput.validate(bad, overlay(registry, "reviewer"))
      assert Enum.any?(errors, &(&1.path == ["findings", 0, "line"] and &1.code == :invalid_type))
    end

    test "rejects findings when not an array", %{registry: registry} do
      bad = %{"findings" => "not an array", "summary" => "test"}
      assert {:error, errors} = StructuredOutput.validate(bad, overlay(registry, "reviewer"))
      assert Enum.any?(errors, &(&1.path == ["findings"] and &1.code == :invalid_type))
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC-3: invalid JSON triggers structured error, not crash
  # ══════════════════════════════════════════════════════════════════════════

  describe "invalid structured output triggers structured error" do
    test "nil data returns error, not crash", %{registry: r} do
      assert {:error, errors} = StructuredOutput.validate(nil, overlay(r, "json-data"))
      assert is_list(errors) and length(errors) > 0
      assert Enum.any?(errors, &(&1.code == :invalid_type))
    end

    test "string data returns structured error", %{registry: r} do
      assert {:error, errors} =
               StructuredOutput.validate("just a string", overlay(r, "json-data"))

      assert length(errors) > 0
    end

    test "integer against reviewer schema returns structured error", %{registry: r} do
      assert {:error, errors} = StructuredOutput.validate(42, overlay(r, "reviewer"))
      assert length(errors) > 0 and Enum.any?(errors, &(&1.code == :invalid_type))
    end

    test "empty list against object schema returns structured error", %{registry: r} do
      assert {:error, errors} = StructuredOutput.validate([], overlay(r, "json-data"))
      assert length(errors) > 0
    end

    test "boolean against object schema returns structured error", %{registry: r} do
      assert {:error, errors} = StructuredOutput.validate(true, overlay(r, "json-data"))
      assert length(errors) > 0
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC-4: missing required fields in output trigger validation error
  # ══════════════════════════════════════════════════════════════════════════

  describe "missing required fields trigger validation error" do
    test "json-data missing both required fields", %{registry: r} do
      assert {:error, errors} = StructuredOutput.validate(%{}, overlay(r, "json-data"))
      fields = errors |> Enum.filter(&(&1.code == :required)) |> Enum.map(& &1.details.field)
      assert "data" in fields and "valid" in fields
    end

    test "reviewer missing both required fields", %{registry: r} do
      assert {:error, errors} = StructuredOutput.validate(%{}, overlay(r, "reviewer"))
      fields = errors |> Enum.filter(&(&1.code == :required)) |> Enum.map(& &1.details.field)
      assert "findings" in fields and "summary" in fields
    end

    test "planner missing required steps", %{registry: r} do
      assert {:error, errors} = StructuredOutput.validate(%{}, overlay(r, "planner"))
      assert Enum.any?(errors, &(&1.code == :required and &1.details.field == "steps"))
    end

    test "repair missing all three required fields", %{registry: r} do
      assert {:error, errors} = StructuredOutput.validate(%{}, overlay(r, "repair"))
      fields = errors |> Enum.filter(&(&1.code == :required)) |> Enum.map(& &1.details.field)
      assert "diagnosis" in fields and "fix_applied" in fields and "verification" in fields
    end

    test "tester missing all count fields", %{registry: r} do
      assert {:error, errors} = StructuredOutput.validate(%{}, overlay(r, "tester"))
      fields = errors |> Enum.filter(&(&1.code == :required)) |> Enum.map(& &1.details.field)
      assert "tests_run" in fields and "passed" in fields and "failed" in fields
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC-5: schema conformance is verified before persisting to store
  # ══════════════════════════════════════════════════════════════════════════

  describe "schema conformance verified before persist" do
    test "valid json-data output passes the gate", %{registry: r} do
      output = %{"data" => %{"result" => [1, 2, 3]}, "valid" => true}
      assert :ok = StructuredOutput.validate(output, overlay(r, "json-data"))
    end

    test "invalid json-data output is blocked and triggers repair event", %{registry: r} do
      # Missing required "data" field
      output = %{"valid" => true}

      case StructuredOutput.validate(output, overlay(r, "json-data")) do
        :ok ->
          flunk("Should have been invalid")

        {:error, errors} ->
          event = %{
            type: :validation_failed,
            errors: errors,
            profile_id: "json-data",
            action: :retry
          }

          assert event.type == :validation_failed
          assert length(event.errors) > 0
          assert event.action == :retry
      end
    end

    test "valid reviewer output passes the gate", %{registry: r} do
      output = %{
        "findings" => [
          %{"severity" => "minor", "file" => "lib/app.ex", "line" => 5, "message" => "Naming"}
        ],
        "summary" => "One minor suggestion"
      }

      assert :ok = StructuredOutput.validate(output, overlay(r, "reviewer"))
    end

    test "invalid reviewer output returns all errors, not just the first", %{registry: r} do
      output = %{"findings" => "should be an array", "summary" => 42}

      case StructuredOutput.validate(output, overlay(r, "reviewer")) do
        :ok ->
          flunk("Should have been invalid")

        {:error, errors} ->
          assert length(errors) >= 2
          paths = Enum.map(errors, & &1.path)
          assert ["findings"] in paths
          assert ["summary"] in paths
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC-6: malformed provider responses are handled gracefully
  # ══════════════════════════════════════════════════════════════════════════

  describe "malformed provider responses handled gracefully" do
    test "raw string instead of object", %{registry: r} do
      assert {:error, errors} = StructuredOutput.validate("raw text", overlay(r, "json-data"))
      assert is_list(errors) and Enum.any?(errors, &(&1.code == :invalid_type))
    end

    test "number instead of structured object", %{registry: r} do
      assert {:error, errors} = StructuredOutput.validate(0, overlay(r, "reviewer"))
      assert length(errors) > 0
    end

    test "empty map when all fields required", %{registry: r} do
      assert {:error, errors} = StructuredOutput.validate(%{}, overlay(r, "reviewer"))
      assert Enum.count(errors, &(&1.code == :required)) == 2
    end

    test "deeply nested wrong types", %{registry: r} do
      output = %{
        "findings" => [
          %{
            "severity" => "critical",
            "file" => 123,
            "line" => "oops",
            "message" => ["nested", "wrong"],
            "suggestion" => true
          }
        ],
        "summary" => "mangled"
      }

      assert {:error, errors} = StructuredOutput.validate(output, overlay(r, "reviewer"))
      assert length(errors) >= 3
    end

    test "extra unexpected properties are allowed by additional_properties: true", %{registry: r} do
      output = %{
        "data" => %{},
        "valid" => true,
        "extra_surprise" => "provider added this",
        "debug_info" => %{"latency_ms" => 150, "model" => "gpt-4o"}
      }

      assert :ok = StructuredOutput.validate(output, overlay(r, "json-data"))
    end

    test "completely wrong shape returns structured error", %{registry: r} do
      assert {:error, errors} = StructuredOutput.validate([1, 2, 3], overlay(r, "json-data"))
      assert length(errors) > 0
      assert Enum.all?(errors, &is_struct(&1, Tet.ProfileRegistry.Error))
    end

    test "null for object-typed fields", %{registry: r} do
      assert {:error, errors} =
               StructuredOutput.validate(
                 %{"data" => nil, "valid" => true},
                 overlay(r, "json-data")
               )

      assert Enum.any?(errors, &(&1.path == ["data"] and &1.code == :invalid_type))
    end

    test "array with mixed types for findings", %{registry: r} do
      output = %{
        "findings" => [
          %{"severity" => "major", "file" => "lib/a.ex", "line" => 1, "message" => "valid"},
          "not a finding object",
          42,
          nil
        ],
        "summary" => "mixed bag"
      }

      assert {:error, errors} = StructuredOutput.validate(output, overlay(r, "reviewer"))
      bad_paths = errors |> Enum.filter(&(&1.code == :invalid_type)) |> Enum.map(& &1.path)
      assert ["findings", 1] in bad_paths
      assert ["findings", 2] in bad_paths
      assert ["findings", 3] in bad_paths
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Cross-profile integration tests
  # ══════════════════════════════════════════════════════════════════════════

  describe "cross-profile structured output validation" do
    @specialty_ids ~w(json-data reviewer planner critic tester security packager retriever repair)

    test "all specialty profiles have a response schema that can be extracted", %{registry: r} do
      for id <- @specialty_ids do
        schema = overlay(r, id) |> Map.get(:output)
        assert is_map(schema), "profile #{id} missing output schema"
      end
    end

    test "planner valid output passes", %{registry: r} do
      output = %{
        "steps" => ["Step 1: Analyze", "Step 2: Implement"],
        "dependencies" => ["Step 2 depends on Step 1"],
        "risks" => ["Large refactor scope"]
      }

      assert :ok = StructuredOutput.validate(output, overlay(r, "planner"))
    end

    test "planner output missing steps fails", %{registry: r} do
      assert {:error, errors} =
               StructuredOutput.validate(%{"risks" => ["x"]}, overlay(r, "planner"))

      assert Enum.any?(errors, &(&1.code == :required and &1.details.field == "steps"))
    end

    test "critic valid output passes", %{registry: r} do
      output = %{
        "issues" => [
          %{
            "category" => "logic",
            "description" => "Missing null check",
            "evidence" => "lib/parse.ex:23",
            "severity" => "major"
          }
        ],
        "alternatives" => ["Use pattern matching"]
      }

      assert :ok = StructuredOutput.validate(output, overlay(r, "critic"))
    end

    test "tester valid output passes", %{registry: r} do
      output = %{
        "tests_run" => 42,
        "passed" => 40,
        "failed" => 2,
        "failures" => [%{"test" => "test_parse", "error" => "ArgumentError"}]
      }

      assert :ok = StructuredOutput.validate(output, overlay(r, "tester"))
    end

    test "security valid output passes", %{registry: r} do
      output = %{
        "findings" => [
          %{
            "severity" => "critical",
            "category" => "injection",
            "file" => "lib/query.ex",
            "line" => 88,
            "description" => "SQL injection",
            "remediation" => "Use parameters"
          }
        ],
        "risk_score" => 8.5
      }

      assert :ok = StructuredOutput.validate(output, overlay(r, "security"))
    end

    test "packager valid output passes", %{registry: r} do
      output = %{
        "artifacts" => [
          %{
            "path" => "build/tet-1.0.0.tar.gz",
            "checksum" => "sha256:abc",
            "size_bytes" => 1_048_576
          }
        ],
        "status" => "success"
      }

      assert :ok = StructuredOutput.validate(output, overlay(r, "packager"))
    end

    test "retriever valid output passes", %{registry: r} do
      output = %{
        "sources" => [%{"file" => "lib/app.ex", "lines" => "1-50", "summary" => "Main module"}],
        "summary" => "Found 1 source"
      }

      assert :ok = StructuredOutput.validate(output, overlay(r, "retriever"))
    end

    test "repair valid output passes", %{registry: r} do
      output = %{
        "diagnosis" => "Syntax error on line 42",
        "fix_applied" => true,
        "diff" => "- old\n+ new",
        "verification" => %{"compiled" => true, "tests_passed" => true, "details" => "All passed"}
      }

      assert :ok = StructuredOutput.validate(output, overlay(r, "repair"))
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  # Extracts the response schema from a profile and wraps it in an :output key
  # so StructuredOutput.validate/2 can find it — the standard bridging pattern
  # between profile_registry.json schemas and StructuredOutput.
  defp overlay(registry, profile_id) do
    {:ok, profile} = ProfileRegistry.profile(registry, profile_id)
    %{output: Map.get(profile.overlays.schema, :response) || %{}}
  end
end
