defmodule Tet.Migration.ConfigMapperTest do
  use ExUnit.Case, async: true

  alias Tet.Migration.ConfigMapper

  describe "compatible_keys/0" do
    test "returns list of known compatible keys" do
      keys = ConfigMapper.compatible_keys()

      assert is_list(keys)
      assert "api_key" in keys
      assert "model" in keys
      assert "base_url" in keys
      assert "data_dir" in keys
      assert "timeout" in keys
      assert "max_tokens" in keys
      assert "temperature" in keys
      assert "session_path" in keys
      assert "verbose" in keys
      assert "auto_save" in keys
      assert "auto_save_interval" in keys
    end
  end

  describe "compatible_mapping/1" do
    test "returns section and new_key for a compatible key" do
      assert {:provider, "api_key"} = ConfigMapper.compatible_mapping("api_key")
      assert {:store, "path"} = ConfigMapper.compatible_mapping("data_dir")
      assert {:provider, "model"} = ConfigMapper.compatible_mapping("model")
      assert {:autosave, "enabled"} = ConfigMapper.compatible_mapping("auto_save")
    end

    test "returns nil for non-compatible key" do
      assert nil == ConfigMapper.compatible_mapping("system_prompt")
      assert nil == ConfigMapper.compatible_mapping("unknown_key")
    end
  end

  describe "unsafe_keys/0" do
    test "returns list of keys requiring manual review" do
      keys = ConfigMapper.unsafe_keys()

      assert is_list(keys)
      assert "system_prompt" in keys
      assert "allowed_tools" in keys
      assert "shell_whitelist" in keys
      assert "custom_headers" in keys
      assert "command_whitelist" in keys
      assert "auto_approve_patterns" in keys
    end

    test "no overlap between compatible and unsafe keys" do
      compatible = MapSet.new(ConfigMapper.compatible_keys())
      unsafe = MapSet.new(ConfigMapper.unsafe_keys())

      assert MapSet.disjoint?(compatible, unsafe)
    end
  end

  describe "map_config/1" do
    test "maps compatible keys to new structure" do
      legacy = %{
        "api_key" => "sk-test",
        "model" => "gpt-4",
        "base_url" => "https://api.example.com"
      }

      assert {:ok, mapped, [], []} = ConfigMapper.map_config(legacy)
      assert mapped["provider"]["api_key"] == "sk-test"
      assert mapped["provider"]["model"] == "gpt-4"
      assert mapped["provider"]["base_url"] == "https://api.example.com"
    end

    test "groups keys into correct sections" do
      legacy = %{
        "data_dir" => "/data",
        "session_path" => "/sessions",
        "verbose" => "true",
        "auto_save" => "yes"
      }

      assert {:ok, mapped, [], []} = ConfigMapper.map_config(legacy)
      assert mapped["store"]["path"] == "/data"
      assert mapped["session"]["path"] == "/sessions"
      assert mapped["logging"]["verbose"] == true
      assert mapped["autosave"]["enabled"] == true
    end

    test "collects unsafe keys" do
      legacy = %{
        "model" => "gpt-4",
        "system_prompt" => "be evil",
        "shell_whitelist" => ["rm"]
      }

      assert {:ok, _mapped, unsafe, []} = ConfigMapper.map_config(legacy)
      assert "system_prompt" in unsafe
      assert "shell_whitelist" in unsafe
      assert "model" not in unsafe
    end

    test "collects unknown keys separately" do
      legacy = %{"model" => "gpt-4", "totally_made_up" => "wat"}

      assert {:ok, mapped, [], unknown} = ConfigMapper.map_config(legacy)
      assert mapped["provider"]["model"] == "gpt-4"
      refute Map.has_key?(mapped, "totally_made_up")
      assert "totally_made_up" in unknown
    end

    test "handles empty config" do
      assert {:ok, %{}, [], []} = ConfigMapper.map_config(%{})
    end
  end

  describe "transform_value/2" do
    test "converts verbose string to boolean" do
      assert ConfigMapper.transform_value("verbose", "true") == true
      assert ConfigMapper.transform_value("verbose", "yes") == true
      assert ConfigMapper.transform_value("verbose", "1") == true
      assert ConfigMapper.transform_value("verbose", "false") == false
      assert ConfigMapper.transform_value("verbose", "no") == false
    end

    test "passes through verbose boolean unchanged" do
      assert ConfigMapper.transform_value("verbose", true) == true
      assert ConfigMapper.transform_value("verbose", false) == false
    end

    test "converts auto_save string to boolean" do
      assert ConfigMapper.transform_value("auto_save", "true") == true
      assert ConfigMapper.transform_value("auto_save", "yes") == true
      assert ConfigMapper.transform_value("auto_save", "false") == false
    end

    test "converts auto_save_interval string to integer" do
      assert ConfigMapper.transform_value("auto_save_interval", "60") == 60
      assert ConfigMapper.transform_value("auto_save_interval", "300") == 300
    end

    test "passes through auto_save_interval integer unchanged" do
      assert ConfigMapper.transform_value("auto_save_interval", 60) == 60
    end

    test "converts timeout string to integer" do
      assert ConfigMapper.transform_value("timeout", "30") == 30
    end

    test "rejects timeout with trailing text (strict parsing)" do
      # Integer.parse("30 seconds") => {30, " seconds"} — should NOT return 30
      assert ConfigMapper.transform_value("timeout", "30 seconds") == "30 seconds"
    end

    test "converts max_tokens string to integer" do
      assert ConfigMapper.transform_value("max_tokens", "4096") == 4096
    end

    test "rejects max_tokens with trailing text" do
      assert ConfigMapper.transform_value("max_tokens", "4096 tokens") == "4096 tokens"
    end

    test "converts temperature string to float" do
      assert ConfigMapper.transform_value("temperature", "0.7") == 0.7
      assert ConfigMapper.transform_value("temperature", "2.0") == 2.0
    end

    test "rejects temperature with trailing text" do
      assert ConfigMapper.transform_value("temperature", "0.7 degrees") == "0.7 degrees"
    end

    test "rejects out-of-range temperature" do
      assert ConfigMapper.transform_value("temperature", "3.0") == "3.0"
    end

    test "passes through unknown keys unchanged" do
      assert ConfigMapper.transform_value("unknown_key", "value") == "value"
      assert ConfigMapper.transform_value("model", "gpt-4") == "gpt-4"
    end
  end
end
