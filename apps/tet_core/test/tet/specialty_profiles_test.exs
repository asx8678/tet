defmodule Tet.SpecialtyProfilesTest do
  use ExUnit.Case, async: true

  alias Tet.ProfileRegistry

  @fixture_dir Path.expand("../fixtures/profile_registry", __DIR__)
  @model_registry_fixture Path.expand("../fixtures/model_registry/valid.json", __DIR__)
  @openai_model "openai/gpt-4o-mini"

  # Specialty profile IDs in alphabetical order (matches fixture key order after decoding)
  @specialty_ids ~w(critic json-data packager planner repair retriever reviewer security tester)

  setup do
    {:ok, model_registry} = load_model_registry()
    {:ok, registry} = load_registry("specialty_profiles.json", model_registry: model_registry)
    %{registry: registry, model_registry: model_registry}
  end

  # ── Validation: all specialty profiles load and validate correctly ──

  test "all nine specialty profiles validate with model cross-references", %{registry: registry} do
    assert registry.schema_version == 1

    for id <- @specialty_ids do
      assert Map.has_key?(registry.profiles, id),
             "expected profile #{inspect(id)} in registry, got: #{inspect(Map.keys(registry.profiles))}"
    end
  end

  test "specialty profiles are listed in deterministic sorted order", %{registry: registry} do
    summaries = ProfileRegistry.list_profiles(registry)
    ids = Enum.map(summaries, & &1.id)

    assert ids == Enum.sort(@specialty_ids)
  end

  # ── Per-profile structural validation ──

  test "planner profile has read-only tools and plan-first task mode", %{registry: registry} do
    {:ok, profile} = ProfileRegistry.profile(registry, "planner")

    assert profile.display_name == "Planner"
    assert profile.overlays.tool.mode == "read_only"
    assert "native.patch.preview" in profile.overlays.tool.allow
    assert "native.patch.apply" in profile.overlays.tool.deny
    assert "native.shell.exec" in profile.overlays.tool.deny
    assert profile.overlays.task.default_mode == "plan"
    assert "plan" in profile.overlays.task.modes
    assert "planning" in profile.overlays.task.categories
    assert profile.overlays.model.default_model == @openai_model
    assert profile.overlays.model.profile_pin == "planner"
    assert profile.overlays.cache.policy == "preserve"
    assert profile.overlays.cache.ttl_seconds == 7200

    # Planner has one prompt layer
    assert [%{id: "plan-before-act"}] = profile.overlays.prompt.layers
  end

  test "reviewer profile has read-only tools and review task mode", %{registry: registry} do
    {:ok, profile} = ProfileRegistry.profile(registry, "reviewer")

    assert profile.display_name == "Reviewer"
    assert profile.overlays.tool.mode == "read_only"
    assert "native.git_diff" in profile.overlays.tool.allow
    assert "native.patch.apply" in profile.overlays.tool.deny
    assert "native.shell.exec" in profile.overlays.tool.deny
    assert profile.overlays.task.default_mode == "review"
    assert "review" in profile.overlays.task.modes
    assert "verification" in profile.overlays.task.categories
    assert profile.overlays.model.default_model == @openai_model
    assert profile.overlays.model.profile_pin == "reviewer"
  end

  test "critic profile has no mutation tools and review task mode", %{registry: registry} do
    {:ok, profile} = ProfileRegistry.profile(registry, "critic")

    assert profile.display_name == "Critic"
    assert profile.overlays.tool.mode == "read_only"
    # Critic denies patch.preview too — no preview of mutations
    assert "native.patch.preview" in profile.overlays.tool.deny
    assert "native.patch.apply" in profile.overlays.tool.deny
    assert "native.shell.exec" in profile.overlays.tool.deny
    assert profile.overlays.task.default_mode == "review"
    assert "verification" in profile.overlays.task.categories
    assert profile.overlays.model.default_model == @openai_model
    assert profile.overlays.model.profile_pin == "critic"

    # Critic has no tool caching
    assert profile.overlays.cache.tools == false
  end

  test "tester profile can apply patches and run tests but not unbounded shell", %{
    registry: registry
  } do
    {:ok, profile} = ProfileRegistry.profile(registry, "tester")

    assert profile.display_name == "Tester"
    assert profile.overlays.tool.mode == "standard"
    assert "native.patch.apply" in profile.overlays.tool.allow
    assert "native.shell.test" in profile.overlays.tool.allow
    assert "native.shell.unbounded" in profile.overlays.tool.deny
    assert "native.patch.apply_unapproved" in profile.overlays.tool.deny
    assert profile.overlays.task.default_mode == "act"
    assert "verify" in profile.overlays.task.modes
    assert profile.overlays.model.default_model == @openai_model
    assert profile.overlays.model.profile_pin == "tester"
    assert profile.overlays.cache.policy == "drop"
  end

  test "security profile is read-only with zero temperature and high priority", %{
    registry: registry
  } do
    {:ok, profile} = ProfileRegistry.profile(registry, "security")

    assert profile.display_name == "Security"
    assert profile.overlays.tool.mode == "read_only"
    assert "native.security.scan" in profile.overlays.tool.allow
    # Security denies patch.preview — no mutation previews at all
    assert "native.patch.preview" in profile.overlays.tool.deny
    assert "native.shell.exec" in profile.overlays.tool.deny
    assert profile.overlays.task.priority == "high"
    assert profile.overlays.task.default_mode == "review"
    assert "verification" in profile.overlays.task.categories
    assert profile.overlays.model.settings["temperature"] == 0.0
    assert profile.overlays.model.profile_pin == "security"
  end

  test "packager profile has build/package tools with deterministic model settings", %{
    registry: registry
  } do
    {:ok, profile} = ProfileRegistry.profile(registry, "packager")

    assert profile.display_name == "Packager"
    assert profile.overlays.tool.mode == "standard"
    assert "native.shell.build" in profile.overlays.tool.allow
    assert "native.shell.package" in profile.overlays.tool.allow
    assert "native.shell.unbounded" in profile.overlays.tool.deny
    assert "network.external" in profile.overlays.tool.deny
    assert profile.overlays.task.categories == ["acting"]
    assert profile.overlays.task.modes == ["act"]
    assert profile.overlays.model.settings["temperature"] == 0.0
    assert profile.overlays.model.profile_pin == "packager"
    assert profile.overlays.cache.policy == "drop"
  end

  test "retriever profile is read-only with broad search tools and assist mode", %{
    registry: registry
  } do
    {:ok, profile} = ProfileRegistry.profile(registry, "retriever")

    assert profile.display_name == "Retriever"
    assert profile.overlays.tool.mode == "read_only"
    assert "native.repo_scan" in profile.overlays.tool.allow
    assert "native.git_diff" in profile.overlays.tool.allow
    # Retriever denies all mutation tools including patch.preview
    assert "native.patch.preview" in profile.overlays.tool.deny
    assert profile.overlays.task.default_mode == "assist"
    assert profile.overlays.task.modes == ["assist"]
    assert profile.overlays.model.profile_pin == "retriever"
    assert profile.overlays.cache.ttl_seconds == 7200
  end

  test "json-data profile has structured output settings and json response format", %{
    registry: registry
  } do
    {:ok, profile} = ProfileRegistry.profile(registry, "json-data")

    assert profile.display_name == "JSON Data"
    assert profile.overlays.tool.mode == "standard"
    assert "native.json.validate" in profile.overlays.tool.allow
    assert "native.patch.apply" in profile.overlays.tool.allow
    assert "native.shell.exec" in profile.overlays.tool.deny
    assert profile.overlays.model.settings["temperature"] == 0.0
    assert profile.overlays.model.settings["response_format"] == "json"
    assert profile.overlays.model.profile_pin == "json-data"
    assert "acting" in profile.overlays.task.categories
  end

  test "repair profile has approval-gated tools and verification capabilities", %{
    registry: registry
  } do
    {:ok, profile} = ProfileRegistry.profile(registry, "repair")

    assert profile.display_name == "Repair"
    assert profile.overlays.tool.mode == "standard"
    assert "native.patch.apply" in profile.overlays.tool.allow
    assert "native.verify.allowlisted" in profile.overlays.tool.allow
    assert "native.shell.test" in profile.overlays.tool.allow
    assert "native.shell.unbounded" in profile.overlays.tool.deny
    assert "native.patch.apply_unapproved" in profile.overlays.tool.deny
    assert profile.overlays.task.priority == "high"
    assert "acting" in profile.overlays.task.categories
    assert "verification" in profile.overlays.task.categories
    assert profile.overlays.model.profile_pin == "repair"
    assert profile.overlays.cache.policy == "drop"

    # Repair has two prompt layers: repair-discipline and approval-gates
    layer_ids = Enum.map(profile.overlays.prompt.layers, & &1.id)
    assert "repair-discipline" in layer_ids
    assert "approval-gates" in layer_ids
  end

  # ── Cross-profile constraint enforcement ──

  test "read-only profiles never allow patch.apply or shell.exec", %{registry: registry} do
    read_only_ids = ~w(planner reviewer critic security retriever)

    for id <- read_only_ids do
      {:ok, profile} = ProfileRegistry.profile(registry, id)

      assert profile.overlays.tool.mode == "read_only",
             "#{id} should be read_only but is #{profile.overlays.tool.mode}"

      assert "native.patch.apply" in profile.overlays.tool.deny,
             "#{id} should deny patch.apply"

      assert "native.shell.exec" in profile.overlays.tool.deny,
             "#{id} should deny shell.exec"
    end
  end

  test "standard-mode profiles deny unbounded shell", %{registry: registry} do
    standard_ids = ~w(tester packager json-data repair)

    for id <- standard_ids do
      {:ok, profile} = ProfileRegistry.profile(registry, id)

      assert profile.overlays.tool.mode == "standard",
             "#{id} should be standard but is #{profile.overlays.tool.mode}"

      assert "native.shell.unbounded" in profile.overlays.tool.deny,
             "#{id} should deny shell.unbounded"
    end
  end

  test "all specialty profiles have disjoint allow and deny tool lists", %{registry: registry} do
    for id <- @specialty_ids do
      {:ok, profile} = ProfileRegistry.profile(registry, id)

      overlap =
        MapSet.intersection(
          MapSet.new(profile.overlays.tool.allow),
          MapSet.new(profile.overlays.tool.deny)
        )

      assert MapSet.size(overlap) == 0,
             "#{id} has overlapping allow/deny tools: #{inspect(MapSet.to_list(overlap))}"
    end
  end

  test "all specialty profiles have valid model selections", %{registry: registry} do
    for id <- @specialty_ids do
      {:ok, profile} = ProfileRegistry.profile(registry, id)

      assert profile.overlays.model.default_model != nil,
             "#{id} must have a default_model"

      assert is_binary(profile.overlays.model.profile_pin),
             "#{id} must have a profile_pin"
    end
  end

  test "all specialty profiles have all six overlay kinds", %{registry: registry} do
    expected_kinds = [:prompt, :tool, :model, :task, :schema, :cache]

    for id <- @specialty_ids do
      {:ok, overlays} = ProfileRegistry.overlays(registry, id)
      actual_kinds = Map.keys(overlays) |> Enum.sort()

      assert actual_kinds == Enum.sort(expected_kinds),
             "#{id} overlays #{inspect(actual_kinds)} != expected #{inspect(Enum.sort(expected_kinds))}"
    end
  end

  test "all specialty profiles have valid default_mode within their declared modes", %{
    registry: registry
  } do
    for id <- @specialty_ids do
      {:ok, profile} = ProfileRegistry.profile(registry, id)
      default = profile.overlays.task.default_mode
      modes = profile.overlays.task.modes

      if default != nil do
        assert default in modes,
               "#{id} default_mode #{inspect(default)} not in modes #{inspect(modes)}"
      end
    end
  end

  test "all specialty profiles have valid cache policies", %{registry: registry} do
    valid_policies = ["preserve", "drop", "replace"]

    for id <- @specialty_ids do
      {:ok, profile} = ProfileRegistry.profile(registry, id)

      assert profile.overlays.cache.policy in valid_policies,
             "#{id} cache policy #{inspect(profile.overlays.cache.policy)} is invalid"
    end
  end

  # ── Overlay lookup via registry API ──

  test "overlay/3 retrieves individual overlays by kind for specialty profiles", %{
    registry: registry
  } do
    for id <- @specialty_ids do
      for kind <- [:prompt, :tool, :model, :task, :schema, :cache] do
        assert {:ok, _overlay} = ProfileRegistry.overlay(registry, id, kind),
               "overlay/3 failed for #{id}/#{kind}"
      end
    end
  end

  test "overlay/3 resolves string kind aliases correctly", %{registry: registry} do
    assert {:ok, _} = ProfileRegistry.overlay(registry, "planner", "tool")
    assert {:ok, _} = ProfileRegistry.overlay(registry, "planner", "model")
    assert :error = ProfileRegistry.overlay(registry, "planner", "telepathy")
  end

  test "inspect_profile returns the same shape as profile for specialty profiles", %{
    registry: registry
  } do
    for id <- @specialty_ids do
      assert {:ok, p1} = ProfileRegistry.profile(registry, id)
      assert {:ok, p2} = ProfileRegistry.inspect_profile(registry, id)
      assert p1 == p2
    end
  end

  # ── Negative validation: corrupting specialty profiles triggers errors ──

  test "rejects planner profile with overlapping allow/deny tools", %{model_registry: mr} do
    raw = specialty_raw()
    raw = set_in(raw, ["profiles", "planner", "overlays", "tool", "deny"], ["native.grep"])

    assert {:error, errors} = ProfileRegistry.validate(raw, model_registry: mr)
    assert Enum.any?(errors, &(&1.code == :invalid_value and "planner" in &1.path))
  end

  test "rejects security profile with invalid cache policy", %{model_registry: mr} do
    raw = specialty_raw()
    raw = set_in(raw, ["profiles", "security", "overlays", "cache", "policy"], "infinite")

    assert {:error, errors} = ProfileRegistry.validate(raw, model_registry: mr)
    assert Enum.any?(errors, &(&1.code == :invalid_value and "security" in &1.path))
  end

  test "rejects tester profile with default_mode outside declared modes", %{model_registry: mr} do
    raw = specialty_raw()
    raw = set_in(raw, ["profiles", "tester", "overlays", "task", "default_mode"], "review")

    assert {:error, errors} = ProfileRegistry.validate(raw, model_registry: mr)
    assert Enum.any?(errors, &(&1.code == :unknown_reference and "tester" in &1.path))
  end

  test "rejects reviewer profile with missing model selection", %{model_registry: mr} do
    raw = specialty_raw()

    raw =
      raw
      |> delete_in(["profiles", "reviewer", "overlays", "model", "default_model"])
      |> delete_in(["profiles", "reviewer", "overlays", "model", "profile_pin"])

    assert {:error, errors} = ProfileRegistry.validate(raw, model_registry: mr)
    assert Enum.any?(errors, &(&1.code == :required and "reviewer" in &1.path))
  end

  test "rejects repair profile with unknown model reference when model registry provided", %{
    model_registry: mr
  } do
    raw = specialty_raw()

    raw =
      set_in(
        raw,
        ["profiles", "repair", "overlays", "model", "default_model"],
        "nonexistent/model"
      )

    assert {:error, errors} = ProfileRegistry.validate(raw, model_registry: mr)
    assert Enum.any?(errors, &(&1.code == :unknown_reference and "repair" in &1.path))
  end

  test "rejects critic profile missing a required overlay kind", %{model_registry: mr} do
    raw = specialty_raw()
    {_value, raw} = pop_in(raw, ["profiles", "critic", "overlays", "cache"])

    assert {:error, errors} = ProfileRegistry.validate(raw, model_registry: mr)
    assert Enum.any?(errors, &(&1.code == :required and "critic" in &1.path))
  end

  # ── Helpers ──

  defp load_registry(name, opts) do
    name
    |> fixture_path()
    |> File.read!()
    |> ProfileRegistry.from_json(opts)
  end

  defp load_model_registry do
    @model_registry_fixture
    |> File.read!()
    |> Tet.ModelRegistry.from_json()
  end

  defp specialty_raw do
    "specialty_profiles.json"
    |> fixture_path()
    |> File.read!()
    |> :json.decode()
  end

  defp fixture_path(name), do: Path.join(@fixture_dir, name)

  defp set_in(raw, [key], value) when is_binary(key), do: Map.put(raw, key, value)

  defp set_in(raw, [key | rest], value) when is_binary(key),
    do: Map.put(raw, key, set_in(raw[key], rest, value))

  defp delete_in(raw, [key]), do: Map.delete(raw, key)
  defp delete_in(raw, [key | rest]), do: Map.put(raw, key, delete_in(raw[key], rest))
end
