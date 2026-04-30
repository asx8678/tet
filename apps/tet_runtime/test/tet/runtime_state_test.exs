defmodule Tet.RuntimeStateTest do
  use ExUnit.Case, async: true

  alias Tet.Runtime.State

  test "new/1 validates required fields and fills runtime-owned defaults" do
    assert {:ok, state} = State.new(%{session_id: " ses_state ", active_profile: "planner"})

    assert state.session_id == "ses_state"
    assert state.active_profile == %{id: "planner", options: %{}}
    assert state.history_ref == nil
    assert state.session_memory_ref == nil
    assert state.task_memory_ref == nil
    assert state.attachments == []
    assert state.active_task_refs == []
    assert state.artifact_refs == []
    assert state.approval_refs == []
    assert state.cache_hints == %{}
    assert state.context == %{}
    assert state.event_log_cursor == nil
    assert state.event_sequence == 0
    assert state.lifecycle == :new
    assert state.turn_status == :idle
    assert state.pending_profile_swap == nil
    assert state.cache_result == nil
    assert state.metadata == %{}
    assert State.safe_to_swap?(state)
    assert {:ok, ^state} = state |> State.to_map() |> State.from_map()

    assert {:error, {:invalid_runtime_state_field, :session_id}} =
             State.new(%{session_id: "", active_profile: "planner"})

    assert {:error, {:invalid_runtime_profile, nil}} =
             State.new(%{session_id: "ses_state"})

    assert {:error, {:invalid_runtime_profile, ""}} =
             State.new(%{session_id: "ses_state", active_profile: ""})

    assert {:error, {:invalid_runtime_profile, false}} =
             State.new(%{session_id: "ses_state", active_profile: false})

    assert {:error, {:invalid_runtime_profile, nil}} =
             State.new(%{session_id: "ses_state", active_profile: %{id: nil}})

    assert {:error, {:invalid_runtime_state_field, :attachments}} =
             State.new(%{session_id: "ses_state", active_profile: "planner", attachments: [123]})
  end

  test "new/1 enforces lifecycle and turn-status invariant" do
    non_idle_statuses = State.turn_statuses() -- [:idle]

    for lifecycle <- [:new, :paused], turn_status <- non_idle_statuses do
      assert {:error, {:invalid_lifecycle_turn_state, ^lifecycle, ^turn_status}} =
               State.new(%{
                 session_id: "ses_#{lifecycle}_#{turn_status}",
                 active_profile: "planner",
                 lifecycle: lifecycle,
                 turn_status: turn_status
               })
    end

    for lifecycle <- [:completed, :failed, :cancelled], turn_status <- non_idle_statuses do
      assert {:error, {:invalid_lifecycle_transition, ^lifecycle, :active}} =
               State.new(%{
                 session_id: "ses_#{lifecycle}_#{turn_status}",
                 active_profile: "planner",
                 lifecycle: lifecycle,
                 turn_status: turn_status
               })
    end

    for lifecycle <- State.lifecycle_statuses() do
      assert {:ok, state} =
               State.new(%{
                 session_id: "ses_#{lifecycle}_idle",
                 active_profile: "planner",
                 lifecycle: lifecycle,
                 turn_status: :idle
               })

      assert state.lifecycle == lifecycle
      assert state.turn_status == :idle
    end

    for turn_status <- non_idle_statuses do
      assert {:ok, state} =
               State.new(%{
                 session_id: "ses_active_#{turn_status}",
                 active_profile: "planner",
                 lifecycle: :active,
                 turn_status: turn_status
               })

      assert state.lifecycle == :active
      assert state.turn_status == turn_status
    end
  end

  test "begin_turn/1 and end_turn/1 expose explicit turn-boundary status" do
    state = State.new!(%{session_id: "ses_turn", active_profile: :planner})

    assert {:ok, in_turn} = State.begin_turn(state)
    assert in_turn.lifecycle == :active
    assert in_turn.turn_status == :in_turn
    refute State.safe_to_swap?(in_turn)

    assert {:error, {:invalid_turn_transition, :in_turn, :in_turn}} = State.begin_turn(in_turn)

    assert {:ok, streaming} = State.put_turn_status(in_turn, :streaming)
    assert streaming.turn_status == :streaming
    refute State.safe_to_swap?(streaming)

    assert {:error, {:invalid_turn_transition, :streaming, :idle}} =
             State.put_turn_status(streaming, :idle)

    assert {:ok, ended} = State.end_turn(streaming)
    assert ended.turn_status == :idle
    assert ended.lifecycle == :active
    assert State.safe_to_swap?(ended)
  end

  test "turn-boundary profile swap preserves durable session, memory, artifact, context, and cache refs" do
    state =
      State.new!(%{
        session_id: "ses_swap",
        active_profile: %{id: "planner", options: %{"mode" => "plan"}},
        history_ref: "hist_1",
        session_memory_ref: "smem_1",
        task_memory_ref: "tmem_1",
        attachments: ["att_1", %{"id" => "att_2", "kind" => "image"}],
        active_task_refs: ["task_1"],
        artifact_refs: ["art_1"],
        approval_refs: ["approval_1"],
        cache_hints: %{"provider" => "openai", "cache_key" => "cache_1"},
        context: %{"compacted_ref" => "ctx_1", "token_count" => 1234},
        event_log_cursor: "evt_42",
        event_sequence: 42,
        metadata: %{"workspace" => "tet"}
      })

    preserved = preserved_fields(state)

    assert {:ok, swapped} =
             State.request_profile_swap(state, %{id: :coder, options: %{"mode" => "act"}},
               cache_capability: :full
             )

    assert swapped.active_profile == %{id: "coder", options: %{"mode" => "act"}}
    assert swapped.pending_profile_swap == nil
    assert swapped.cache_result == :preserved
    assert preserved_fields(swapped) == preserved
    assert swapped.event_sequence == 42
  end

  test "mid-turn profile swap queues by default and applies at end_turn/1" do
    state =
      State.new!(%{
        session_id: "ses_queue",
        active_profile: "planner",
        attachments: ["att_1"],
        active_task_refs: ["task_1"],
        artifact_refs: ["art_1"],
        approval_refs: ["approval_1"],
        cache_hints: %{"cache_key" => "cache_1"},
        context: %{"summary_ref" => "ctx_1"},
        event_sequence: 7
      })

    assert {:ok, in_turn} = State.begin_turn(state)
    assert {:ok, queued} = State.request_profile_swap(in_turn, "reviewer")

    assert queued.active_profile == %{id: "planner", options: %{}}
    assert queued.pending_profile_swap.to_profile == %{id: "reviewer", options: %{}}
    assert queued.pending_profile_swap.from_profile == %{id: "planner", options: %{}}
    assert queued.pending_profile_swap.mode == :queue_until_turn_boundary
    assert queued.pending_profile_swap.blocked_by == :in_turn
    refute State.safe_to_swap?(queued)

    assert {:ok, swapped} = State.end_turn(queued)
    assert swapped.active_profile == %{id: "reviewer", options: %{}}
    assert swapped.pending_profile_swap == nil
    assert swapped.attachments == ["att_1"]
    assert swapped.active_task_refs == ["task_1"]
    assert swapped.artifact_refs == ["art_1"]
    assert swapped.approval_refs == ["approval_1"]
    # Default cache_capability is :none; :preserve + :none => :reset, so hints are cleared
    assert swapped.cache_hints == %{}
    assert swapped.context == %{"summary_ref" => "ctx_1"}
    assert swapped.turn_status == :idle
    assert swapped.cache_result == :reset
  end

  test "mid-turn profile swap can be rejected as structured data" do
    state = State.new!(%{session_id: "ses_reject", active_profile: "planner"})
    {:ok, in_turn} = State.begin_turn(state)

    assert {:error, {:unsafe_profile_swap, request}} =
             State.request_profile_swap(in_turn, "tester", mode: :reject_mid_turn)

    assert request.from_profile == %{id: "planner", options: %{}}
    assert request.to_profile == %{id: "tester", options: %{}}
    assert request.mode == :reject_mid_turn
    assert request.blocked_by == :in_turn
    assert request.requested_at_sequence == 0
    assert request.cache_policy == :preserve
    assert in_turn.active_profile == %{id: "planner", options: %{}}
    assert in_turn.pending_profile_swap == nil
  end

  test "terminal lifecycle rejects profile swaps instead of queuing zombie requests" do
    for lifecycle <- [:completed, :failed, :cancelled] do
      state =
        State.new!(%{
          session_id: "ses_terminal_#{lifecycle}",
          active_profile: "planner",
          lifecycle: lifecycle
        })

      refute State.safe_to_swap?(state)

      assert {:error, {:unsafe_profile_swap, request}} =
               State.request_profile_swap(state, "coder")

      assert request.from_profile == %{id: "planner", options: %{}}
      assert request.to_profile == %{id: "coder", options: %{}}
      assert request.blocked_by == :idle
      assert state.pending_profile_swap == nil
    end
  end

  test "terminal lifecycle cannot be deserialized or transitioned back into active work" do
    for lifecycle <- [:completed, :failed, :cancelled] do
      attrs = %{session_id: "ses_terminal_invariant_#{lifecycle}", active_profile: "planner"}

      assert {:error, {:invalid_lifecycle_transition, ^lifecycle, :active}} =
               State.from_map(
                 Map.merge(attrs, %{
                   lifecycle: Atom.to_string(lifecycle),
                   turn_status: "streaming"
                 })
               )

      pending = %{from_profile: "planner", to_profile: "coder", mode: "queue_until_turn_boundary"}

      assert {:error, {:unsafe_profile_swap, _request}} =
               State.from_map(
                 Map.merge(attrs, %{lifecycle: lifecycle, pending_profile_swap: pending})
               )

      terminal = %{State.new!(Map.put(attrs, :lifecycle, lifecycle)) | turn_status: :in_turn}

      assert {:error, {:invalid_lifecycle_transition, ^lifecycle, :active}} =
               State.put_turn_status(terminal, :tool_running)

      assert {:error, {:invalid_lifecycle_transition, ^lifecycle, :active}} =
               State.end_turn(terminal)
    end
  end

  test "queued swaps are explicit and cannot be applied or overwritten at safe boundary" do
    pending = %{
      from_profile: "planner",
      to_profile: "coder",
      mode: "queue_until_turn_boundary",
      requested_at_sequence: 3,
      blocked_by: "in_turn"
    }

    assert {:ok, state} =
             State.from_map(%{
               session_id: "ses_pending_boundary",
               active_profile: "planner",
               lifecycle: :active,
               turn_status: :idle,
               event_sequence: 3,
               pending_profile_swap: pending
             })

    assert State.safe_to_swap?(state)

    assert {:error, {:profile_swap_already_pending, existing}} =
             State.request_profile_swap(state, "tester")

    assert existing == state.pending_profile_swap
    assert state.active_profile == %{id: "planner", options: %{}}

    assert {:ok, swapped} = State.apply_pending_profile_swap(state)
    assert swapped.active_profile == %{id: "coder", options: %{}}
    assert swapped.pending_profile_swap == nil
  end

  test "queued swaps are explicit and cannot be applied or overwritten mid-turn" do
    state = State.new!(%{session_id: "ses_pending", active_profile: "planner"})
    {:ok, in_turn} = State.begin_turn(state)
    {:ok, queued} = State.request_profile_swap(in_turn, "coder")

    assert {:error, {:unsafe_profile_swap, pending}} = State.apply_pending_profile_swap(queued)
    assert pending == queued.pending_profile_swap

    assert {:error, {:profile_swap_already_pending, existing}} =
             State.request_profile_swap(queued, "tester")

    assert existing == queued.pending_profile_swap
  end

  test "from_map/1 rejects invalid string statuses and swap modes" do
    base = %{session_id: "ses_invalid_strings", active_profile: "planner"}

    assert {:error, {:invalid_runtime_state_field, :lifecycle}} =
             State.from_map(Map.put(base, :lifecycle, "garbage"))

    assert {:error, {:invalid_runtime_state_field, :turn_status}} =
             State.from_map(Map.put(base, :turn_status, "garbage"))

    attrs =
      Map.put(base, :pending_profile_swap, %{
        from_profile: "planner",
        to_profile: "coder",
        mode: "teleport_mid_sentence"
      })

    assert {:error, {:invalid_runtime_state_field, :mode}} = State.from_map(attrs)
  end

  test "cache hints are preserved with explicit :full capability, reset by default, and context metadata survives" do
    state =
      State.new!(%{
        session_id: "ses_cache",
        active_profile: "coder",
        cache_hints: %{"provider" => "openai", "cache_key" => "prefix_1"},
        context: %{"compacted_ref" => "ctx_1", "prompt_fingerprint" => "fp_1"}
      })

    # Without explicit cache_capability, defaults to :none => :preserve + :none = :reset
    assert {:ok, defaulted} = State.request_profile_swap(state, "reviewer")
    assert defaulted.cache_hints == %{}
    assert defaulted.context == state.context
    assert defaulted.cache_result == :reset

    # With explicit :full capability, hints are preserved
    assert {:ok, preserved} =
             State.request_profile_swap(state, "reviewer", cache_capability: :full)

    assert preserved.cache_hints == state.cache_hints
    assert preserved.context == state.context
    assert preserved.cache_result == :preserved

    assert {:ok, dropped} = State.request_profile_swap(state, "tester", cache_policy: :drop)
    assert dropped.cache_hints == %{}
    assert dropped.context == state.context
    assert dropped.cache_result == :reset

    replacement = %{"provider" => "anthropic", "cache_key" => "prefix_2"}

    assert {:ok, replaced} =
             State.request_profile_swap(state, "repair",
               cache_policy: {:replace, replacement},
               cache_capability: :full
             )

    assert replaced.cache_hints == replacement
    assert replaced.context == state.context
    assert replaced.cache_result == :preserved
  end

  test "cache_result starts nil and records outcome after each swap" do
    state =
      State.new!(%{
        session_id: "ses_cache_result",
        active_profile: "planner",
        cache_hints: %{"provider" => "anthropic", "cache_key" => "cache_1"}
      })

    assert state.cache_result == nil

    {:ok, swapped} = State.request_profile_swap(state, "coder", cache_policy: :drop)
    assert swapped.cache_result == :reset

    {:ok, swapped_again} =
      State.request_profile_swap(swapped, "reviewer",
        cache_policy: :preserve,
        cache_capability: :full
      )

    assert swapped_again.cache_result == :preserved
  end

  test "cache_result round-trips through to_map/from_map" do
    state =
      State.new!(%{
        session_id: "ses_cache_roundtrip",
        active_profile: "planner",
        cache_hints: %{"cache_key" => "c1"},
        cache_result: :summarized
      })

    mapped = State.to_map(state)
    assert mapped.cache_result == "summarized"

    assert {:ok, roundtripped} = State.from_map(mapped)
    assert roundtripped.cache_result == :summarized
    assert roundtripped == state
  end

  test "cache_result rejects invalid values" do
    assert {:error, {:invalid_runtime_state_field, :cache_result}} =
             State.new(%{
               session_id: "ses_bad_result",
               active_profile: "planner",
               cache_result: :kaboom
             })

    assert {:error, {:invalid_runtime_state_field, :cache_result}} =
             State.new(%{
               session_id: "ses_bad_result2",
               active_profile: "planner",
               cache_result: "nope"
             })
  end

  test "cache_capability produces :summarized when adapter supports :summary only" do
    state =
      State.new!(%{
        session_id: "ses_summary_cap",
        active_profile: "planner",
        cache_hints: %{"cache_key" => "cache_1"}
      })

    {:ok, swapped} =
      State.request_profile_swap(state, "coder",
        cache_policy: :preserve,
        cache_capability: :summary
      )

    assert swapped.cache_result == :summarized
    # When cache_result is :summarized, raw provider cache hints must not
    # remain active; the summary/context handoff is recorded separately.
    assert swapped.cache_hints == %{}

    {:ok, replaced} =
      State.request_profile_swap(
        swapped,
        "reviewer",
        cache_policy: {:replace, %{"cache_key" => "cache_2"}},
        cache_capability: :summary
      )

    assert replaced.cache_result == :summarized
    # :summarized clears raw hints even with :replace policy
    assert replaced.cache_hints == %{}
  end

  test "cache_capability :none resets even with :preserve policy" do
    state =
      State.new!(%{
        session_id: "ses_none_cap",
        active_profile: "planner",
        cache_hints: %{"cache_key" => "cache_1"}
      })

    {:ok, swapped} =
      State.request_profile_swap(state, "coder", cache_policy: :preserve, cache_capability: :none)

    assert swapped.cache_result == :reset
    # When cache_result is :reset, active cache_hints must be cleared
    assert swapped.cache_hints == %{}
  end

  test "cache_capability :drop always resets regardless of adapter capability" do
    state =
      State.new!(%{
        session_id: "ses_drop_always",
        active_profile: "planner",
        cache_hints: %{"cache_key" => "cache_1"}
      })

    for cap <- [:full, :summary, :none] do
      {:ok, swapped} =
        State.request_profile_swap(state, "coder", cache_policy: :drop, cache_capability: cap)

      assert swapped.cache_result == :reset
      assert swapped.cache_hints == %{}
    end
  end

  test "cache_capability defaults to :none avoiding false :preserved claims" do
    state =
      State.new!(%{
        session_id: "ses_default_cap",
        active_profile: "planner",
        cache_hints: %{"cache_key" => "cache_1"}
      })

    # Without explicit cache_capability, the conservative :none default
    # prevents claiming :preserved when capability is undeclared.
    {:ok, swapped} = State.request_profile_swap(state, "coder")
    assert swapped.cache_result == :reset
    assert swapped.cache_hints == %{}
  end

  test "cache_capability rejects invalid values" do
    state =
      State.new!(%{
        session_id: "ses_bad_cap",
        active_profile: "planner"
      })

    assert {:error, {:invalid_runtime_state_field, :cache_capability}} =
             State.request_profile_swap(state, "coder", cache_capability: :kaboom)

    assert {:error, {:invalid_runtime_state_field, :cache_capability}} =
             State.request_profile_swap(state, "coder", cache_capability: "nope")
  end

  test "regression: omitted cache_capability never claims :preserved" do
    state =
      State.new!(%{
        session_id: "ses_omit_cap_regression",
        active_profile: "planner",
        cache_hints: %{"cache_key" => "old_hint"}
      })

    # Every swap without explicit cache_capability must produce :reset,
    # never silently claim :preserved.
    for policy <- [:preserve, :drop] do
      {:ok, swapped} =
        State.request_profile_swap(
          %{state | cache_hints: %{"cache_key" => "old_hint"}},
          "coder",
          cache_policy: policy
        )

      assert swapped.cache_result == :reset
      assert swapped.cache_hints == %{}
    end
  end

  test "cache_capability round-trips through pending profile swap serialization" do
    state =
      State.new!(%{
        session_id: "ses_cap_roundtrip",
        active_profile: "planner"
      })

    # Start a turn so swap gets queued
    {:ok, in_turn} = State.begin_turn(state)
    {:ok, queued} = State.put_turn_status(in_turn, :streaming)

    {:ok, with_pending} =
      State.request_profile_swap(
        queued,
        "coder",
        cache_policy: :preserve,
        cache_capability: :summary
      )

    assert with_pending.pending_profile_swap.cache_capability == :summary

    # End the turn, which applies the pending swap
    {:ok, applied} = State.end_turn(with_pending)
    assert applied.cache_result == :summarized
  end

  test "to_map/1 and from_map/1 round-trip queued swap state" do
    state =
      State.new!(%{
        session_id: "ses_roundtrip",
        active_profile: %{id: "planner", version: "1", options: %{"tone" => "tiny gremlin"}},
        history_ref: %{"kind" => "event_log", "id" => "hist_1"},
        session_memory_ref: "smem_1",
        task_memory_ref: "tmem_1",
        attachments: ["att_1"],
        active_task_refs: ["task_1"],
        artifact_refs: ["art_1"],
        approval_refs: ["approval_1"],
        cache_hints: %{"cache_key" => "cache_1"},
        context: %{"compacted_ref" => "ctx_1"},
        event_log_cursor: 12,
        event_sequence: 12,
        metadata: %{"operator" => "adam"}
      })

    {:ok, in_turn} = State.begin_turn(state)

    replacement_cache = %{"provider" => "openai", "cache_key" => "cache_2"}

    {:ok, queued} =
      State.request_profile_swap(in_turn, %{id: "coder", options: %{"style" => "dry"}},
        cache_policy: {:replace, replacement_cache},
        metadata: %{"requested_by" => "test"}
      )

    mapped = State.to_map(queued)

    assert mapped.pending_profile_swap.cache_policy == %{
             mode: "replace",
             cache_hints: replacement_cache
           }

    assert :json.encode(mapped)

    assert {:ok, roundtripped} = State.from_map(mapped)
    assert roundtripped == queued
  end

  defp preserved_fields(state) do
    Map.take(state, [
      :session_id,
      :history_ref,
      :session_memory_ref,
      :task_memory_ref,
      :attachments,
      :active_task_refs,
      :artifact_refs,
      :approval_refs,
      :cache_hints,
      :context,
      :event_log_cursor,
      :metadata
    ])
  end
end
