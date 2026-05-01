defmodule Tet.ProfileRegistry.StructuredOutputTest do
  use ExUnit.Case, async: true

  alias Tet.ProfileRegistry.StructuredOutput

  describe "validate/2" do
    # ── Happy path ───────────────────────────────────────────────────────────

    test "validates null type" do
      assert :ok = StructuredOutput.validate(nil, %{output: %{"type" => "null"}})
    end

    test "validates boolean type" do
      assert :ok = StructuredOutput.validate(true, %{output: %{"type" => "boolean"}})
      assert :ok = StructuredOutput.validate(false, %{output: %{"type" => "boolean"}})
    end

    test "validates integer type" do
      assert :ok = StructuredOutput.validate(42, %{output: %{"type" => "integer"}})
      assert :ok = StructuredOutput.validate(0, %{output: %{"type" => "integer"}})
      assert :ok = StructuredOutput.validate(-1, %{output: %{"type" => "integer"}})
    end

    test "validates number type" do
      assert :ok = StructuredOutput.validate(3.14, %{output: %{"type" => "number"}})
      assert :ok = StructuredOutput.validate(42, %{output: %{"type" => "number"}})
    end

    test "validates string type" do
      assert :ok = StructuredOutput.validate("hello", %{output: %{"type" => "string"}})
      assert :ok = StructuredOutput.validate("", %{output: %{"type" => "string"}})
    end

    test "validates array type" do
      assert :ok = StructuredOutput.validate([], %{output: %{"type" => "array"}})
      assert :ok = StructuredOutput.validate([1, 2, 3], %{output: %{"type" => "array"}})
    end

    test "validates object type" do
      assert :ok = StructuredOutput.validate(%{}, %{output: %{"type" => "object"}})

      assert :ok =
               StructuredOutput.validate(%{"key" => "value"}, %{output: %{"type" => "object"}})
    end

    test "validates nested object with properties" do
      schema = %{
        output: %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string"},
            "age" => %{"type" => "integer"},
            "active" => %{"type" => "boolean"}
          }
        }
      }

      assert :ok =
               StructuredOutput.validate(
                 %{"name" => "Alice", "age" => 30, "active" => true},
                 schema
               )
    end

    test "validates array with items schema" do
      schema = %{
        output: %{
          "type" => "array",
          "items" => %{"type" => "string"}
        }
      }

      assert :ok = StructuredOutput.validate(["a", "b", "c"], schema)
    end

    test "validates enum" do
      schema = %{output: %{"type" => "string", "enum" => ["red", "green", "blue"]}}
      assert :ok = StructuredOutput.validate("red", schema)
      assert :ok = StructuredOutput.validate("green", schema)
      assert :ok = StructuredOutput.validate("blue", schema)
    end

    test "validates pattern (regex)" do
      schema = %{output: %{"type" => "string", "pattern" => "^[a-z]+$"}}
      assert :ok = StructuredOutput.validate("hello", schema)
    end

    test "validates numeric range" do
      schema = %{output: %{"type" => "integer", "minimum" => 1, "maximum" => 100}}
      assert :ok = StructuredOutput.validate(50, schema)
      assert :ok = StructuredOutput.validate(1, schema)
      assert :ok = StructuredOutput.validate(100, schema)
    end

    test "validates string length" do
      schema = %{output: %{"type" => "string", "minLength" => 2, "maxLength" => 5}}
      assert :ok = StructuredOutput.validate("ab", schema)
      assert :ok = StructuredOutput.validate("hello", schema)
    end

    test "validates array length" do
      schema = %{output: %{"type" => "array", "minItems" => 1, "maxItems" => 3}}
      assert :ok = StructuredOutput.validate([1], schema)
      assert :ok = StructuredOutput.validate([1, 2, 3], schema)
    end

    test "validates required fields present" do
      schema = %{
        output: %{
          "type" => "object",
          "required" => ["name", "email"],
          "properties" => %{
            "name" => %{"type" => "string"},
            "email" => %{"type" => "string"}
          }
        }
      }

      assert :ok =
               StructuredOutput.validate(
                 %{"name" => "Alice", "email" => "alice@example.com"},
                 schema
               )
    end

    test "validates additionalProperties: false with no extra keys" do
      schema = %{
        output: %{
          "type" => "object",
          "properties" => %{"name" => %{"type" => "string"}},
          "additionalProperties" => false
        }
      }

      assert :ok = StructuredOutput.validate(%{"name" => "Alice"}, schema)
    end

    test "validates additionalProperties with schema" do
      schema = %{
        output: %{
          "type" => "object",
          "properties" => %{"name" => %{"type" => "string"}},
          "additionalProperties" => %{"type" => "integer"}
        }
      }

      assert :ok =
               StructuredOutput.validate(%{"name" => "Alice", "age" => 30, "count" => 5}, schema)
    end

    test "accepts additionalProperties when not specified" do
      schema = %{
        output: %{
          "type" => "object",
          "properties" => %{"name" => %{"type" => "string"}}
        }
      }

      assert :ok = StructuredOutput.validate(%{"name" => "Alice", "extra" => "ok"}, schema)
    end

    test "validates $ref resolution from root $defs" do
      schema = %{
        output: %{
          "$defs" => %{
            "color" => %{"type" => "string", "enum" => ["red", "green", "blue"]}
          },
          "type" => "object",
          "properties" => %{
            "primary" => %{"$ref" => "#/$defs/color"}
          }
        }
      }

      assert :ok = StructuredOutput.validate(%{"primary" => "red"}, schema)
    end

    test "returns :ok when schema_overlay has no output field" do
      assert :ok = StructuredOutput.validate("anything", %{})
    end

    test "returns :ok when schema_overlay is not a map" do
      assert :ok = StructuredOutput.validate("anything", nil)
      assert :ok = StructuredOutput.validate("anything", "not a map")
    end

    # ── Sad path: type errors ────────────────────────────────────────────────

    test "rejects wrong type for null" do
      assert {:error, [error]} = StructuredOutput.validate(42, %{output: %{"type" => "null"}})
      assert error.path == []
      assert error.code == :invalid_type
      assert error.details.expected == "null"
    end

    test "rejects wrong type for boolean" do
      assert {:error, [error]} =
               StructuredOutput.validate("not bool", %{output: %{"type" => "boolean"}})

      assert error.path == []
      assert error.code == :invalid_type
      assert error.details.expected == "boolean"
    end

    test "rejects wrong type for integer" do
      assert {:error, [error]} =
               StructuredOutput.validate(3.14, %{output: %{"type" => "integer"}})

      assert error.path == []
      assert error.code == :invalid_type
      assert error.details.expected == "integer"
    end

    test "rejects wrong type for string" do
      assert {:error, [error]} = StructuredOutput.validate(42, %{output: %{"type" => "string"}})
      assert error.path == []
      assert error.code == :invalid_type
      assert error.details.expected == "string"
    end

    test "rejects wrong type for array" do
      assert {:error, [error]} = StructuredOutput.validate(%{}, %{output: %{"type" => "array"}})
      assert error.path == []
      assert error.code == :invalid_type
      assert error.details.expected == "array"
    end

    test "rejects wrong type for object" do
      assert {:error, [error]} = StructuredOutput.validate([], %{output: %{"type" => "object"}})
      assert error.path == []
      assert error.code == :invalid_type
      assert error.details.expected == "object"
    end

    test "rejects wrong type in nested properties" do
      schema = %{
        output: %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string"}
          }
        }
      }

      assert {:error, [error]} = StructuredOutput.validate(%{"name" => 42}, schema)
      assert error.path == ["name"]
      assert error.code == :invalid_type
      assert error.details.expected == "string"
    end

    test "rejects wrong type in array items" do
      schema = %{
        output: %{
          "type" => "array",
          "items" => %{"type" => "integer"}
        }
      }

      assert {:error, [error]} = StructuredOutput.validate([1, "bad", 3], schema)
      assert error.path == [1]
      assert error.code == :invalid_type
      assert error.details.expected == "integer"
    end

    # ── Sad path: required fields ────────────────────────────────────────────

    test "rejects missing required fields" do
      schema = %{
        output: %{
          "type" => "object",
          "required" => ["name", "email"],
          "properties" => %{
            "name" => %{"type" => "string"},
            "email" => %{"type" => "string"}
          }
        }
      }

      assert {:error, errors} = StructuredOutput.validate(%{"name" => "Alice"}, schema)
      assert length(errors) == 1
      error = Enum.find(errors, &(&1.code == :required))
      assert error.path == ["email"]
      assert error.message =~ "required"
      assert error.details.field == "email"
    end

    # ── Sad path: enum violations ────────────────────────────────────────────

    test "rejects values not in enum" do
      schema = %{output: %{"type" => "string", "enum" => ["red", "green", "blue"]}}
      assert {:error, [error]} = StructuredOutput.validate("yellow", schema)
      assert error.path == []
      assert error.code == :invalid_value
      assert error.details.allowed == ["red", "green", "blue"]
    end

    # ── Sad path: pattern violations ─────────────────────────────────────────

    test "rejects values that don't match pattern" do
      schema = %{output: %{"type" => "string", "pattern" => "^[a-z]+$"}}
      assert {:error, [error]} = StructuredOutput.validate("Hello123", schema)
      assert error.path == []
      assert error.code == :invalid_value
      assert error.details.value == "Hello123"
    end

    # ── Sad path: range violations ───────────────────────────────────────────

    test "rejects values below minimum" do
      schema = %{output: %{"type" => "integer", "minimum" => 1}}
      assert {:error, [error]} = StructuredOutput.validate(0, schema)
      assert error.path == []
      assert error.code == :invalid_value
      assert error.details.constraint == :minimum
      assert error.details.limit == 1
    end

    test "rejects values above maximum" do
      schema = %{output: %{"type" => "integer", "maximum" => 100}}
      assert {:error, [error]} = StructuredOutput.validate(101, schema)
      assert error.path == []
      assert error.code == :invalid_value
      assert error.details.constraint == :maximum
      assert error.details.limit == 100
    end

    # ── Sad path: length violations ──────────────────────────────────────────

    test "rejects strings below minLength" do
      schema = %{output: %{"type" => "string", "minLength" => 3}}
      assert {:error, [error]} = StructuredOutput.validate("ab", schema)
      assert error.path == []
      assert error.code == :invalid_value
      assert error.details.constraint == :minLength
      assert error.details.limit == 3
    end

    test "rejects strings above maxLength" do
      schema = %{output: %{"type" => "string", "maxLength" => 3}}
      assert {:error, [error]} = StructuredOutput.validate("abcd", schema)
      assert error.path == []
      assert error.code == :invalid_value
      assert error.details.constraint == :maxLength
      assert error.details.limit == 3
    end

    test "rejects arrays below minItems" do
      schema = %{output: %{"type" => "array", "minItems" => 2}}
      assert {:error, [error]} = StructuredOutput.validate([1], schema)
      assert error.path == []
      assert error.code == :invalid_value
      assert error.details.constraint == :minItems
      assert error.details.limit == 2
    end

    test "rejects arrays above maxItems" do
      schema = %{output: %{"type" => "array", "maxItems" => 2}}
      assert {:error, [error]} = StructuredOutput.validate([1, 2, 3], schema)
      assert error.path == []
      assert error.code == :invalid_value
      assert error.details.constraint == :maxItems
      assert error.details.limit == 2
    end

    # ── Sad path: additionalProperties = false ───────────────────────────────

    test "rejects extra properties when additionalProperties is false" do
      schema = %{
        output: %{
          "type" => "object",
          "properties" => %{"name" => %{"type" => "string"}},
          "additionalProperties" => false
        }
      }

      assert {:error, [error]} =
               StructuredOutput.validate(%{"name" => "Alice", "age" => 30}, schema)

      assert error.path == ["age"]
      assert error.code == :invalid_value
      assert error.message =~ "unexpected property"
      assert error.details.key == "age"
    end

    test "rejects extra properties matching additionalProperties schema when type mismatches" do
      schema = %{
        output: %{
          "type" => "object",
          "properties" => %{"name" => %{"type" => "string"}},
          "additionalProperties" => %{"type" => "integer"}
        }
      }

      assert {:error, [error]} =
               StructuredOutput.validate(%{"name" => "Alice", "age" => "not integer"}, schema)

      assert error.path == ["age"]
      assert error.code == :invalid_type
      assert error.details.expected == "integer"
    end

    # ── Sad path: deep nesting ───────────────────────────────────────────────

    test "validates deeply nested structures" do
      schema = %{
        output: %{
          "type" => "object",
          "properties" => %{
            "data" => %{
              "type" => "object",
              "properties" => %{
                "items" => %{
                  "type" => "array",
                  "items" => %{
                    "type" => "object",
                    "properties" => %{
                      "id" => %{"type" => "integer"},
                      "label" => %{"type" => "string"}
                    },
                    "required" => ["id"]
                  }
                }
              }
            }
          }
        }
      }

      valid_data = %{
        "data" => %{
          "items" => [
            %{"id" => 1, "label" => "one"},
            %{"id" => 2, "label" => "two"}
          ]
        }
      }

      assert :ok = StructuredOutput.validate(valid_data, schema)

      invalid_data = %{
        "data" => %{
          "items" => [
            %{"id" => "not int"},
            %{"label" => "missing id"}
          ]
        }
      }

      assert {:error, errors} = StructuredOutput.validate(invalid_data, schema)
      assert length(errors) == 2

      type_error =
        Enum.find(errors, &(&1.path == ["data", "items", 0, "id"] and &1.code == :invalid_type))

      assert type_error != nil

      missing_error =
        Enum.find(errors, &(&1.path == ["data", "items", 1, "id"] and &1.code == :required))

      assert missing_error != nil
    end

    # ── Boolean false handling ───────────────────────────────────────────────

    test "handles false boolean values in properties" do
      schema = %{
        output: %{
          "type" => "object",
          "properties" => %{
            "active" => %{"type" => "boolean"},
            "flag" => %{"type" => "boolean"}
          }
        }
      }

      assert :ok = StructuredOutput.validate(%{"active" => false, "flag" => false}, schema)
    end

    test "handles false as additionalProperties correctly using Map.has_key?" do
      # Testing that false in additionalProperties means "no extra properties"
      # NOT that it's treated as absent
      schema_with_false_ap = %{
        output: %{
          "type" => "object",
          "properties" => %{"name" => %{"type" => "string"}},
          "additionalProperties" => false
        }
      }

      schema_without_ap = %{
        output: %{
          "type" => "object",
          "properties" => %{"name" => %{"type" => "string"}}
        }
      }

      # With false, extra props are rejected
      assert {:error, _} =
               StructuredOutput.validate(%{"name" => "A", "extra" => true}, schema_with_false_ap)

      # Without additionalProperties, extra props are allowed
      assert :ok =
               StructuredOutput.validate(%{"name" => "A", "extra" => true}, schema_without_ap)
    end

    test "handles false value in a property correctly" do
      schema = %{
        output: %{
          "type" => "object",
          "properties" => %{
            "debug" => %{"type" => "boolean"},
            "name" => %{"type" => "string"}
          },
          "required" => ["debug"]
        }
      }

      assert :ok = StructuredOutput.validate(%{"debug" => false, "name" => "test"}, schema)
    end

    # ── Malformed input handling ─────────────────────────────────────────────

    test "does not crash on non-map schema" do
      assert :ok = StructuredOutput.validate("anything", %{output: "not a map"})
    end

    test "does not crash on unknown type keyword" do
      assert {:error, [error]} =
               StructuredOutput.validate(42, %{output: %{"type" => "unknown_type"}})

      assert error.code == :invalid_type
      assert error.details.expected == "unknown_type"
    end

    test "does not crash on invalid regex pattern" do
      schema = %{output: %{"type" => "string", "pattern" => "[invalid"}}
      assert :ok = StructuredOutput.validate("hello", schema)
    end

    test "does not crash when enum is not a list" do
      schema = %{output: %{"type" => "string", "enum" => "not_a_list"}}
      assert :ok = StructuredOutput.validate("hello", schema)
    end

    test "does not crash when properties is not a map" do
      schema = %{output: %{"type" => "object", "properties" => "not_a_map"}}
      assert :ok = StructuredOutput.validate(%{"key" => "value"}, schema)
    end

    test "does not crash when items is not a map" do
      schema = %{output: %{"type" => "array", "items" => "not_a_map"}}
      assert :ok = StructuredOutput.validate([1, 2, 3], schema)
    end

    test "does not crash when required is not a list" do
      schema = %{
        output: %{
          "type" => "object",
          "properties" => %{"name" => %{"type" => "string"}},
          "required" => "not_a_list"
        }
      }

      assert :ok = StructuredOutput.validate(%{"name" => "Alice"}, schema)
    end

    test "does not crash on non-map schema_overlay" do
      assert :ok = StructuredOutput.validate("hello", nil)
    end

    test "does not crash on $ref pointing to non-existent location" do
      schema = %{
        output: %{
          "type" => "object",
          "properties" => %{
            "foo" => %{"$ref" => "#/$defs/nonexistent"}
          }
        }
      }

      assert :ok = StructuredOutput.validate(%{"foo" => "bar"}, schema)
    end

    test "does not crash on $ref with non-string value" do
      schema = %{
        output: %{
          "type" => "object",
          "properties" => %{
            "foo" => %{"$ref" => 42}
          }
        }
      }

      assert :ok = StructuredOutput.validate(%{"foo" => "bar"}, schema)
    end

    test "does not crash on minimum/maximum with non-numeric value" do
      schema = %{output: %{"type" => "integer", "minimum" => "not_a_number"}}
      assert :ok = StructuredOutput.validate(42, schema)
    end

    test "does not crash on minLength/maxLength with non-integer value" do
      schema = %{output: %{"type" => "string", "minLength" => "not_an_int"}}
      assert :ok = StructuredOutput.validate("hello", schema)
    end

    # ── $ref resolution ──────────────────────────────────────────────────────

    test "resolves $ref with atom keys in schema" do
      schema = %{
        output: %{
          "$defs" => %{
            "name" => %{"type" => "string"}
          },
          "type" => "object",
          "properties" => %{
            "user" => %{"$ref" => "#/$defs/name"}
          }
        }
      }

      assert :ok = StructuredOutput.validate(%{"user" => "Alice"}, schema)
      assert {:error, [error]} = StructuredOutput.validate(%{"user" => 42}, schema)
      assert error.path == ["user"]
      assert error.code == :invalid_type
    end

    test "resolves nested $ref" do
      schema = %{
        output: %{
          "$defs" => %{
            "address" => %{
              "type" => "object",
              "properties" => %{
                "city" => %{"type" => "string"},
                "zip" => %{"type" => "string"}
              }
            }
          },
          "type" => "object",
          "properties" => %{
            "shipping" => %{"$ref" => "#/$defs/address"},
            "billing" => %{"$ref" => "#/$defs/address"}
          }
        }
      }

      data = %{
        "shipping" => %{"city" => "NYC", "zip" => "10001"},
        "billing" => %{"city" => "LA", "zip" => "90001"}
      }

      assert :ok = StructuredOutput.validate(data, schema)

      bad_data = %{
        "shipping" => %{"city" => "NYC", "zip" => 10_001}
      }

      assert {:error, [error]} = StructuredOutput.validate(bad_data, schema)
      assert error.path == ["shipping", "zip"]
      assert error.code == :invalid_type
    end

    # ── Error paths ──────────────────────────────────────────────────────────

    test "error paths are correctly threaded through nesting" do
      schema = %{
        output: %{
          "type" => "object",
          "properties" => %{
            "level1" => %{
              "type" => "object",
              "properties" => %{
                "level2" => %{
                  "type" => "array",
                  "items" => %{
                    "type" => "object",
                    "properties" => %{
                      "value" => %{"type" => "integer"}
                    }
                  }
                }
              }
            }
          }
        }
      }

      data = %{
        "level1" => %{
          "level2" => [
            %{"value" => 1},
            %{"value" => "not_int"}
          ]
        }
      }

      assert {:error, [error]} = StructuredOutput.validate(data, schema)
      assert error.path == ["level1", "level2", 1, "value"]
      assert error.code == :invalid_type
    end

    # ── Empty/missing output schema ──────────────────────────────────────────

    test "returns :ok when output schema is empty map" do
      assert :ok = StructuredOutput.validate("anything", %{output: %{}})
    end

    test "returns :ok when output schema is nil in overlay" do
      assert :ok = StructuredOutput.validate("anything", %{output: nil})
    end

    # ── Multiple errors ──────────────────────────────────────────────────────

    test "collects multiple validation errors" do
      schema = %{
        output: %{
          "type" => "object",
          "properties" => %{
            "a" => %{"type" => "integer"},
            "b" => %{"type" => "integer"}
          },
          "required" => ["a", "b", "c"]
        }
      }

      assert {:error, errors} =
               StructuredOutput.validate(%{"a" => "not int", "b" => "also not int"}, schema)

      assert length(errors) == 3
      codes = Enum.map(errors, & &1.code)
      assert :invalid_type in codes
      assert :required in codes
    end

    # ── additionalProperties with empty properties ───────────────────────────

    test "additionalProperties: false with empty properties rejects all keys" do
      schema = %{
        output: %{
          "type" => "object",
          "properties" => %{},
          "additionalProperties" => false
        }
      }

      assert {:error, [error]} = StructuredOutput.validate(%{"anything" => 1}, schema)
      assert error.path == ["anything"]
      assert error.code == :invalid_value
    end

    test "additionalProperties: true behaves the same as not present" do
      schema = %{
        output: %{
          "type" => "object",
          "properties" => %{"name" => %{"type" => "string"}},
          "additionalProperties" => true
        }
      }

      assert :ok = StructuredOutput.validate(%{"name" => "Alice", "extra" => "fine"}, schema)
    end
  end
end
