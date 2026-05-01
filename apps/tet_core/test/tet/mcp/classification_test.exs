defmodule Tet.Mcp.ClassificationTest do
  use ExUnit.Case, async: true

  alias Tet.Mcp.Classification

  describe "categories/0" do
    test "returns all five risk categories in ascending severity" do
      assert Classification.categories() == [:read, :write, :shell, :network, :admin]
    end
  end

  describe "risk_levels/0" do
    test "returns all four risk levels" do
      assert Classification.risk_levels() == [:low, :medium, :high, :critical]
    end
  end

  describe "classify/1" do
    test "classifies read tools as :read" do
      for name <-
            ~w(read_file get_status list_items search_index view_data show_diff inspect_value head_info query_db count_rows) do
        assert Classification.classify(%{name: name}) == :read,
               "expected #{name} → :read"
      end
    end

    test "classifies write tools as :write" do
      for name <-
            ~w(write_file create_record update_entry delete_item remove_old patch_code save_data insert_row add_item set_value put_object modify_field rename_file move_item copy_data) do
        assert Classification.classify(%{name: name}) == :write,
               "expected #{name} → :write"
      end
    end

    test "classifies shell tools as :shell" do
      for name <- ~w(run_command exec_bash shell_out build_project compile_code evaluate_expr) do
        assert Classification.classify(%{name: name}) == :shell,
               "expected #{name} → :shell"
      end
    end

    test "classifies network tools as :network" do
      for name <-
            ~w(fetch_url http_request curl_data ping_host connect_api upload_file download_asset call_proxy) do
        assert Classification.classify(%{name: name}) == :network,
               "expected #{name} → :network"
      end
    end

    test "classifies admin tools as :admin" do
      for name <-
            ~w(admin_panel config_system manage_users sudo_action install_pkg uninstall_dep deploy_app grant_access revoke_token permissions_check) do
        assert Classification.classify(%{name: name}) == :admin,
               "expected #{name} → :admin"
      end
    end

    test "trusts explicit mcp_category over heuristic" do
      assert Classification.classify(%{name: "read_file", mcp_category: :shell}) == :shell
      assert Classification.classify(%{name: "run_bash", mcp_category: :read}) == :read
      assert Classification.classify(%{name: "x", mcp_category: :admin}) == :admin
    end

    test "unknown tools default to :write (fail-closed)" do
      assert Classification.classify(%{name: "unknown_tool_xyz"}) == :write
      assert Classification.classify(%{name: "foobar"}) == :write
    end

    test "case-insensitive classification" do
      assert Classification.classify(%{name: "Read_File"}) == :read
      assert Classification.classify(%{name: "RUN_Bash"}) == :shell
      assert Classification.classify(%{name: "ADMIN_Panel"}) == :admin
    end

    test "admin has highest precedence in heuristic matching" do
      # "admin" appears in name → admin, even if name also contains "read"
      assert Classification.classify(%{name: "admin_read_settings"}) == :admin
    end

    test "shell has higher precedence than write/read" do
      assert Classification.classify(%{name: "shell_write_data"}) == :shell
    end

    test "invalid descriptor defaults to :write" do
      assert Classification.classify(nil) == :write
      assert Classification.classify(%{}) == :write
    end
  end

  describe "risk_level/1" do
    test "maps each category to its risk level" do
      assert Classification.risk_level(:read) == :low
      assert Classification.risk_level(:write) == :medium
      assert Classification.risk_level(:shell) == :high
      assert Classification.risk_level(:network) == :high
      assert Classification.risk_level(:admin) == :critical
    end
  end

  describe "safe?/1" do
    test "only :read is safe" do
      assert Classification.safe?(:read) == true
      assert Classification.safe?(:write) == false
      assert Classification.safe?(:shell) == false
      assert Classification.safe?(:network) == false
      assert Classification.safe?(:admin) == false
    end
  end

  describe "requires_approval?/1" do
    test "read does not require approval" do
      assert Classification.requires_approval?(:read) == false
    end

    test "everything else requires approval" do
      assert Classification.requires_approval?(:write) == true
      assert Classification.requires_approval?(:shell) == true
      assert Classification.requires_approval?(:network) == true
      assert Classification.requires_approval?(:admin) == true
    end
  end
end
