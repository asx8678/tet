defmodule Tet.CacheHandoffTest do
  use ExUnit.Case, async: true

  alias Tet.Runtime.Provider.CacheHandoff
  alias Tet.Provider

  # ── CacheHandoff.resolve/2 ──

  describe "resolve/2 with :preserve policy" do
    test "returns :preserved when adapter has :full cache capability" do
      assert CacheHandoff.resolve(:preserve, :full) == :preserved
    end

    test "returns :summarized when adapter has :summary cache capability" do
      assert CacheHandoff.resolve(:preserve, :summary) == :summarized
    end

    test "returns :reset when adapter has :none cache capability" do
      assert CacheHandoff.resolve(:preserve, :none) == :reset
    end
  end

  describe "resolve/2 with :drop policy" do
    test "always returns :reset regardless of adapter capability" do
      for capability <- [:full, :summary, :none] do
        assert CacheHandoff.resolve(:drop, capability) == :reset
      end
    end
  end

  describe "resolve/2 with {:replace, _} policy" do
    test "returns :preserved when adapter has :full cache capability" do
      replacement = %{"provider" => "anthropic", "cache_key" => "prefix_2"}
      assert CacheHandoff.resolve({:replace, replacement}, :full) == :preserved
    end

    test "returns :summarized when adapter has :summary cache capability" do
      replacement = %{"provider" => "openai", "cache_key" => "prefix_3"}
      assert CacheHandoff.resolve({:replace, replacement}, :summary) == :summarized
    end

    test "returns :reset when adapter has :none cache capability" do
      replacement = %{"provider" => "mock", "cache_key" => "prefix_4"}
      assert CacheHandoff.resolve({:replace, replacement}, :none) == :reset
    end
  end

  # ── CacheHandoff.resolve_from_swap/2 ──

  describe "resolve_from_swap/2" do
    test "resolves from a swap request struct and target adapter" do
      swap_request = %{
        from_profile: %{id: "planner", options: %{}},
        to_profile: %{id: "coder", options: %{}},
        mode: :queue_until_turn_boundary,
        cache_policy: :preserve,
        requested_at_sequence: 1,
        blocked_by: :idle
      }

      assert CacheHandoff.resolve_from_swap(swap_request, Tet.Runtime.Provider.Mock) == :reset
    end

    test "resolves :drop policy regardless of adapter" do
      swap_request = %{
        from_profile: %{id: "planner", options: %{}},
        to_profile: %{id: "coder", options: %{}},
        mode: :queue_until_turn_boundary,
        cache_policy: :drop,
        requested_at_sequence: 2,
        blocked_by: :idle
      }

      assert CacheHandoff.resolve_from_swap(swap_request, Tet.Runtime.Provider.Mock) == :reset
    end
  end

  # ── CacheHandoff.results/0 ──

  describe "results/0" do
    test "returns all valid cache result atoms in stable order" do
      assert CacheHandoff.results() == [:preserved, :summarized, :reset]
    end
  end

  # ── CacheHandoff.normalize_result/1 ──

  describe "normalize_result/1" do
    test "accepts valid atoms" do
      for result <- CacheHandoff.results() do
        assert {:ok, ^result} = CacheHandoff.normalize_result(result)
      end
    end

    test "accepts valid strings" do
      assert {:ok, :preserved} = CacheHandoff.normalize_result("preserved")
      assert {:ok, :summarized} = CacheHandoff.normalize_result("summarized")
      assert {:ok, :reset} = CacheHandoff.normalize_result("reset")
    end

    test "trims whitespace from strings" do
      assert {:ok, :preserved} = CacheHandoff.normalize_result("  preserved  ")
      assert {:ok, :summarized} = CacheHandoff.normalize_result("\t summarized ")
    end

    test "rejects invalid values" do
      assert {:error, {:invalid_cache_result, "exploded"}} =
               CacheHandoff.normalize_result("exploded")

      assert {:error, {:invalid_cache_result, :kaboom}} = CacheHandoff.normalize_result(:kaboom)
      assert {:error, {:invalid_cache_result, 42}} = CacheHandoff.normalize_result(42)
    end
  end

  # ── Provider.cache_capability/1 ──

  describe "Provider.cache_capability/1" do
    test "returns :none for adapters without the callback" do
      defmodule NoCapabilityAdapter do
        @behaviour Tet.Provider

        @impl true
        def stream_chat(_messages, _opts, _emit), do: {:ok, %{content: ""}}
      end

      assert Provider.cache_capability(NoCapabilityAdapter) == :none
    end

    test "returns the declared capability for adapters that implement it" do
      defmodule FullCapabilityAdapter do
        @behaviour Tet.Provider

        @impl true
        def cache_capability, do: :full

        @impl true
        def stream_chat(_messages, _opts, _emit), do: {:ok, %{content: ""}}
      end

      defmodule SummaryCapabilityAdapter do
        @behaviour Tet.Provider

        @impl true
        def cache_capability, do: :summary

        @impl true
        def stream_chat(_messages, _opts, _emit), do: {:ok, %{content: ""}}
      end

      assert Provider.cache_capability(FullCapabilityAdapter) == :full
      assert Provider.cache_capability(SummaryCapabilityAdapter) == :summary
    end

    test "returns :none for Mock provider" do
      assert Provider.cache_capability(Tet.Runtime.Provider.Mock) == :none
    end

    test "returns :summary for OpenAI compatible provider" do
      assert Provider.cache_capability(Tet.Runtime.Provider.OpenAICompatible) == :summary
    end
  end

  # ── Tet.Event.profile_swap_cache_result/3 ──

  describe "Tet.Event.profile_swap_cache_result/3" do
    test "builds event with correct type and payload" do
      for result <- CacheHandoff.results() do
        event = Tet.Event.profile_swap_cache_result(result, %{from: "planner", to: "coder"})
        assert event.type == :profile_swap_cache_result
        assert event.payload.cache_result == result
        assert event.payload.from == "planner"
        assert event.payload.to == "coder"
      end
    end

    test "accepts session_id in opts" do
      event =
        Tet.Event.profile_swap_cache_result(:preserved, %{}, session_id: "ses_123")

      assert event.session_id == "ses_123"
    end

    test "round-trips through to_map/from_map" do
      event =
        Tet.Event.profile_swap_cache_result(:summarized, %{
          from: "planner",
          to: "reviewer"
        })

      mapped = Tet.Event.to_map(event)
      assert mapped.type == "profile_swap_cache_result"
      assert mapped.payload["cache_result"] == "summarized"

      assert {:ok, roundtripped} = Tet.Event.from_map(mapped)
      assert roundtripped.type == :profile_swap_cache_result
      # from_map preserves string keys in payload; the value round-trips as a string
      assert roundtripped.payload["cache_result"] == "summarized"
    end
  end
end
