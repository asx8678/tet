defmodule Tet.FindingStoreTest do
  use ExUnit.Case, async: false

  @moduletag :tet_core

  setup do
    original_store = Application.get_env(:tet_core, :store_adapter)
    Application.put_env(:tet_core, :store_adapter, Tet.Store.Memory)
    Tet.Store.Memory.reset()

    on_exit(fn ->
      if original_store do
        Application.put_env(:tet_core, :store_adapter, original_store)
      else
        Application.delete_env(:tet_core, :store_adapter)
      end
    end)

    :ok
  end

  # ============================================================
  # Finding struct tests
  # ============================================================

  describe "Tet.Finding.new/1" do
    test "builds a valid finding from atom-keyed attrs" do
      assert {:ok, finding} =
               Tet.Finding.new(%{
                 id: "fnd_001",
                 session_id: "ses_001",
                 title: "Test finding",
                 source: :event,
                 severity: :warning,
                 status: :open
               })

      assert finding.id == "fnd_001"
      assert finding.session_id == "ses_001"
      assert finding.title == "Test finding"
      assert finding.source == :event
      assert finding.severity == :warning
      assert finding.status == :open
    end

    test "builds a valid finding from string-keyed attrs" do
      assert {:ok, finding} =
               Tet.Finding.new(%{
                 "id" => "fnd_str",
                 "session_id" => "ses_str",
                 "title" => "String keys",
                 "source" => "tool_run",
                 "severity" => "critical",
                 "status" => "open"
               })

      assert finding.id == "fnd_str"
      assert finding.source == :tool_run
      assert finding.severity == :critical
    end

    test "defaults severity to :info when omitted" do
      assert {:ok, finding} =
               Tet.Finding.new(%{
                 id: "fnd_def",
                 session_id: "ses_001",
                 title: "Default severity",
                 source: :event
               })

      assert finding.severity == :info
    end

    test "defaults status to :open when omitted" do
      assert {:ok, finding} =
               Tet.Finding.new(%{
                 id: "fnd_status",
                 session_id: "ses_001",
                 title: "Default status",
                 source: :manual
               })

      assert finding.status == :open
    end

    test "accepts all valid sources" do
      for source <- Tet.Finding.sources() do
        assert {:ok, finding} =
                 Tet.Finding.new(%{
                   id: "fnd_src_#{source}",
                   session_id: "ses_001",
                   title: "Source test",
                   source: source
                 })

        assert finding.source == source
      end
    end

    test "rejects invalid source" do
      assert {:error, _} =
               Tet.Finding.new(%{
                 id: "fnd_bad_src",
                 session_id: "ses_001",
                 title: "Bad source",
                 source: :invalid_source
               })
    end

    test "rejects missing required fields" do
      assert {:error, _} = Tet.Finding.new(%{id: "fnd_no_session", title: "No session"})
      assert {:error, _} = Tet.Finding.new(%{session_id: "ses_001", title: "No id"})
      assert {:error, _} = Tet.Finding.new(%{id: "fnd_no_title", session_id: "ses_001"})
    end

    test "accepts optional task_id, description, and evidence_refs" do
      assert {:ok, finding} =
               Tet.Finding.new(%{
                 id: "fnd_opts",
                 session_id: "ses_001",
                 title: "With optionals",
                 source: :review,
                 task_id: "tsk_001",
                 description: "A detailed finding",
                 evidence_refs: [%{type: :event, id: "evt_001"}]
               })

      assert finding.task_id == "tsk_001"
      assert finding.description == "A detailed finding"
      assert length(finding.evidence_refs) == 1
    end
  end

  describe "Tet.Finding.promote/3" do
    test "promotes finding to persistent_memory with correct target" do
      {:ok, finding} = valid_finding_attrs() |> Tet.Finding.new()
      now = DateTime.utc_now()

      promoted = Tet.Finding.promote(finding, {:persistent_memory, "pm_001"}, now)

      assert promoted.status == :promoted
      assert promoted.promoted_to == {:persistent_memory, "pm_001"}
      assert promoted.promoted_at == now
    end

    test "promotes finding to project_lesson with correct target" do
      {:ok, finding} = valid_finding_attrs() |> Tet.Finding.new()
      now = DateTime.utc_now()

      promoted = Tet.Finding.promote(finding, {:project_lesson, "pl_001"}, now)

      assert promoted.status == :promoted
      assert promoted.promoted_to == {:project_lesson, "pl_001"}
      assert promoted.promoted_at == now
    end
  end

  describe "Tet.Finding.dismiss/1" do
    test "dismisses an open finding" do
      {:ok, finding} = valid_finding_attrs() |> Tet.Finding.new()
      dismissed = Tet.Finding.dismiss(finding)

      assert dismissed.status == :dismissed
    end
  end

  describe "Tet.Finding.to_map/1" do
    test "converts to JSON-friendly map" do
      {:ok, finding} = valid_finding_attrs() |> Tet.Finding.new()
      map = Tet.Finding.to_map(finding)

      assert is_map(map)
      assert map[:id] == "fnd_tomap"
      assert map[:source] == "event"
      assert map[:severity] == "warning"
      assert map[:status] == "open"
    end

    test "round-trips through to_map/from_map" do
      {:ok, original} = valid_finding_attrs() |> Tet.Finding.new()
      map = Tet.Finding.to_map(original)
      assert {:ok, restored} = Tet.Finding.from_map(map)
      assert restored.id == original.id
      assert restored.session_id == original.session_id
      assert restored.title == original.title
    end

    test "promoted finding round-trips through to_map/from_map" do
      {:ok, finding} = valid_finding_attrs() |> Tet.Finding.new()
      now = DateTime.utc_now()
      promoted = Tet.Finding.promote(finding, {:persistent_memory, "pm_001"}, now)

      map = Tet.Finding.to_map(promoted)
      assert {:ok, restored} = Tet.Finding.from_map(map)

      assert restored.id == promoted.id
      assert restored.status == :promoted
      assert restored.promoted_to == {:persistent_memory, "pm_001"}
      assert restored.promoted_at != nil
    end

    test "promoted-to-project-lesson finding round-trips through to_map/from_map" do
      {:ok, finding} = valid_finding_attrs() |> Tet.Finding.new()
      now = DateTime.utc_now()
      promoted = Tet.Finding.promote(finding, {:project_lesson, "pl_001"}, now)

      map = Tet.Finding.to_map(promoted)
      assert {:ok, restored} = Tet.Finding.from_map(map)

      assert restored.id == promoted.id
      assert restored.status == :promoted
      assert restored.promoted_to == {:project_lesson, "pl_001"}
    end
  end

  # ============================================================
  # PersistentMemory struct tests
  # ============================================================

  describe "Tet.PersistentMemory.new/1" do
    test "builds a valid persistent memory entry" do
      assert {:ok, pm} =
               Tet.PersistentMemory.new(%{
                 id: "pm_001",
                 session_id: "ses_001",
                 title: "Important observation",
                 source_finding_id: "fnd_001",
                 severity: :critical
               })

      assert pm.id == "pm_001"
      assert pm.source_finding_id == "fnd_001"
      assert pm.severity == :critical
    end

    test "requires source_finding_id" do
      assert {:error, _} =
               Tet.PersistentMemory.new(%{
                 id: "pm_no_src",
                 session_id: "ses_001",
                 title: "No source"
               })
    end

    test "severity is optional" do
      assert {:ok, pm} =
               Tet.PersistentMemory.new(%{
                 id: "pm_no_sev",
                 session_id: "ses_001",
                 title: "No severity",
                 source_finding_id: "fnd_001"
               })

      assert pm.severity == nil
    end

    test "to_map round-trips" do
      {:ok, pm} =
        Tet.PersistentMemory.new(%{
          id: "pm_rt",
          session_id: "ses_001",
          title: "Round trip",
          source_finding_id: "fnd_001",
          severity: :warning
        })

      map = Tet.PersistentMemory.to_map(pm)
      assert {:ok, restored} = Tet.PersistentMemory.from_map(map)
      assert restored.id == pm.id
      assert restored.source_finding_id == pm.source_finding_id
    end
  end

  # ============================================================
  # ProjectLesson struct tests
  # ============================================================

  describe "Tet.ProjectLesson.new/1" do
    test "builds a valid project lesson" do
      assert {:ok, lesson} =
               Tet.ProjectLesson.new(%{
                 id: "pl_001",
                 title: "Always use transactions",
                 category: :convention,
                 source_finding_id: "fnd_001"
               })

      assert lesson.id == "pl_001"
      assert lesson.category == :convention
      assert lesson.source_finding_id == "fnd_001"
    end

    test "accepts all valid categories" do
      for cat <- Tet.ProjectLesson.categories() do
        assert {:ok, lesson} =
                 Tet.ProjectLesson.new(%{
                   id: "pl_cat_#{cat}",
                   title: "Category test",
                   category: cat,
                   source_finding_id: "fnd_001"
                 })

        assert lesson.category == cat
      end
    end

    test "category is optional" do
      assert {:ok, lesson} =
               Tet.ProjectLesson.new(%{
                 id: "pl_no_cat",
                 title: "No category",
                 source_finding_id: "fnd_001"
               })

      assert lesson.category == nil
    end

    test "requires source_finding_id" do
      assert {:error, _} =
               Tet.ProjectLesson.new(%{
                 id: "pl_no_src",
                 title: "No source finding"
               })
    end

    test "to_map round-trips" do
      {:ok, lesson} =
        Tet.ProjectLesson.new(%{
          id: "pl_rt",
          title: "Round trip lesson",
          category: :repair_strategy,
          source_finding_id: "fnd_001"
        })

      map = Tet.ProjectLesson.to_map(lesson)
      assert {:ok, restored} = Tet.ProjectLesson.from_map(map)
      assert restored.id == lesson.id
      assert restored.category == lesson.category
    end
  end

  # ============================================================
  # FindingStore facade tests
  # ============================================================

  describe "Tet.FindingStore.record_finding/1,2,3" do
    test "records a finding with default store" do
      assert {:ok, finding} =
               Tet.FindingStore.record_finding(%{
                 id: "fnd_rec_001",
                 session_id: "ses_001",
                 title: "Recorded finding",
                 source: :event,
                 severity: :warning
               })

      assert finding.id == "fnd_rec_001"
      assert finding.status == :open
      assert finding.created_at != nil
    end

    test "records with explicit store module" do
      assert {:ok, finding} =
               Tet.FindingStore.record_finding(
                 Tet.Store.Memory,
                 %{
                   id: "fnd_explicit",
                   session_id: "ses_001",
                   title: "Explicit store",
                   source: :tool_run
                 },
                 []
               )

      assert finding.id == "fnd_explicit"
    end
  end

  describe "Tet.FindingStore.get_finding/1,2,3" do
    test "fetches a recorded finding" do
      record("ses_get", "fnd_get_001")

      assert {:ok, finding} = Tet.FindingStore.get_finding("fnd_get_001")
      assert finding.id == "fnd_get_001"
    end

    test "returns error for missing finding" do
      assert {:error, _} = Tet.FindingStore.get_finding("fnd_nonexistent")
    end
  end

  describe "Tet.FindingStore.list_findings/1,2,3" do
    test "returns empty list for session with no findings" do
      assert {:ok, []} = Tet.FindingStore.list_findings("ses_empty")
    end

    test "returns findings for a session" do
      record("ses_list", "fnd_l1")
      record("ses_list", "fnd_l2")
      record("ses_other", "fnd_l3")

      assert {:ok, findings} = Tet.FindingStore.list_findings("ses_list")
      assert length(findings) == 2
    end
  end

  describe "Tet.FindingStore.update_finding/2,3,4" do
    test "updates mutable fields on a finding" do
      record("ses_upd", "fnd_upd_001")

      assert {:ok, updated} =
               Tet.FindingStore.update_finding("fnd_upd_001", %{
                 severity: :critical,
                 description: "Updated description"
               })

      assert updated.severity == :critical
      assert updated.description == "Updated description"
    end

    test "returns error for missing finding" do
      assert {:error, _} =
               Tet.FindingStore.update_finding("fnd_nonexistent", %{severity: :critical})
    end

    test "protects identity fields from mutation" do
      record("ses_protect", "fnd_protect")

      assert {:ok, updated} =
               Tet.FindingStore.update_finding("fnd_protect", %{
                 id: "hacked_id",
                 session_id: "hacked_sid",
                 source: :review,
                 title: "Hacked title",
                 severity: :critical
               })

      # Mutable field changed
      assert updated.severity == :critical
      # Identity fields unchanged
      assert updated.id == "fnd_protect"
      assert updated.session_id == "ses_protect"
      assert updated.source == :event
      assert updated.title == "Test finding"
    end
  end

  # ============================================================
  # Promotion: Finding → Persistent Memory
  # ============================================================

  describe "Tet.FindingStore.promote_to_persistent_memory/1,2" do
    test "creates persistent memory and promotes finding" do
      record("ses_promote", "fnd_pm_001")

      assert {:ok, {finding, pm}} =
               Tet.FindingStore.promote_to_persistent_memory("fnd_pm_001")

      # Finding is promoted
      assert finding.id == "fnd_pm_001"
      assert finding.status == :promoted
      assert finding.promoted_to == {:persistent_memory, pm.id}
      assert finding.promoted_at != nil

      # Persistent memory entry created
      assert pm.source_finding_id == "fnd_pm_001"
      assert pm.title == "Test finding"
      assert pm.session_id == "ses_promote"
      assert pm.promoted_at != nil
    end

    test "persistent memory is retrievable after promotion" do
      record("ses_pm_ret", "fnd_pm_ret")

      assert {:ok, {_, pm}} =
               Tet.FindingStore.promote_to_persistent_memory("fnd_pm_ret")

      assert {:ok, fetched} = Tet.FindingStore.get_persistent_memory(pm.id)
      assert fetched.source_finding_id == "fnd_pm_ret"
    end

    test "promoted finding appears in list_persistent_memories" do
      record("ses_pm_list", "fnd_pm_list")

      assert {:ok, _} =
               Tet.FindingStore.promote_to_persistent_memory("fnd_pm_list")

      assert {:ok, entries} = Tet.FindingStore.list_persistent_memories("ses_pm_list")
      assert length(entries) == 1
    end

    test "rejects already-promoted finding" do
      record("ses_pm_dup", "fnd_pm_dup")

      assert {:ok, _} = Tet.FindingStore.promote_to_persistent_memory("fnd_pm_dup")

      assert {:error, :finding_already_promoted} =
               Tet.FindingStore.promote_to_persistent_memory("fnd_pm_dup")
    end

    test "rejects dismissed finding" do
      record("ses_pm_dismiss", "fnd_pm_dismiss")

      assert {:ok, _} = Tet.FindingStore.dismiss_finding("fnd_pm_dismiss")

      assert {:error, :finding_dismissed} =
               Tet.FindingStore.promote_to_persistent_memory("fnd_pm_dismiss")
    end

    test "rejects missing finding" do
      assert {:error, :finding_not_found} =
               Tet.FindingStore.promote_to_persistent_memory("fnd_nonexistent")
    end

    test "passes extra metadata to persistent memory" do
      record("ses_pm_meta", "fnd_pm_meta")

      assert {:ok, {_, pm}} =
               Tet.FindingStore.promote_to_persistent_memory(
                 "fnd_pm_meta",
                 metadata: %{domain: "testing"}
               )

      assert pm.metadata[:domain] == "testing"
    end
  end

  # ============================================================
  # Promotion: Finding → Project Lesson
  # ============================================================

  describe "Tet.FindingStore.promote_to_project_lesson/1,2" do
    test "creates project lesson and promotes finding" do
      record("ses_lesson", "fnd_pl_001")

      assert {:ok, {finding, lesson}} =
               Tet.FindingStore.promote_to_project_lesson("fnd_pl_001",
                 category: :convention
               )

      # Finding is promoted
      assert finding.id == "fnd_pl_001"
      assert finding.status == :promoted
      assert finding.promoted_to == {:project_lesson, lesson.id}
      assert finding.promoted_at != nil

      # Project lesson created
      assert lesson.source_finding_id == "fnd_pl_001"
      assert lesson.title == "Test finding"
      assert lesson.category == :convention
      assert lesson.promoted_at != nil
    end

    test "project lesson is retrievable after promotion" do
      record("ses_pl_ret", "fnd_pl_ret")

      assert {:ok, {_, lesson}} =
               Tet.FindingStore.promote_to_project_lesson("fnd_pl_ret",
                 category: :error_pattern
               )

      assert {:ok, fetched} = Tet.FindingStore.get_project_lesson(lesson.id)
      assert fetched.source_finding_id == "fnd_pl_ret"
      assert fetched.category == :error_pattern
    end

    test "promoted lesson appears in list_project_lessons" do
      record("ses_pl_list", "fnd_pl_list")

      assert {:ok, _} =
               Tet.FindingStore.promote_to_project_lesson("fnd_pl_list",
                 category: :repair_strategy
               )

      assert {:ok, lessons} = Tet.FindingStore.list_project_lessons()
      assert length(lessons) >= 1
    end

    test "list_project_lessons filters by category" do
      Tet.Store.Memory.reset()

      record("ses_pl_f1", "fnd_f1")
      record("ses_pl_f2", "fnd_f2")

      Tet.FindingStore.promote_to_project_lesson("fnd_f1", category: :convention)
      Tet.FindingStore.promote_to_project_lesson("fnd_f2", category: :security)

      assert {:ok, lessons} = Tet.FindingStore.list_project_lessons(category: :convention)
      assert length(lessons) == 1
      assert hd(lessons).category == :convention
    end

    test "rejects already-promoted finding" do
      record("ses_pl_dup", "fnd_pl_dup")

      assert {:ok, _} =
               Tet.FindingStore.promote_to_project_lesson("fnd_pl_dup",
                 category: :verification
               )

      assert {:error, :finding_already_promoted} =
               Tet.FindingStore.promote_to_project_lesson("fnd_pl_dup")
    end

    test "rejects dismissed finding" do
      record("ses_pl_dismiss", "fnd_pl_dismiss")

      assert {:ok, _} = Tet.FindingStore.dismiss_finding("fnd_pl_dismiss")

      assert {:error, :finding_dismissed} =
               Tet.FindingStore.promote_to_project_lesson("fnd_pl_dismiss")
    end
  end

  # ============================================================
  # Dismiss finding
  # ============================================================

  describe "Tet.FindingStore.dismiss_finding/1,2" do
    test "dismisses an open finding" do
      record("ses_dismiss", "fnd_dismiss_001")

      assert {:ok, dismissed} = Tet.FindingStore.dismiss_finding("fnd_dismiss_001")
      assert dismissed.status == :dismissed
    end

    test "rejects already dismissed finding" do
      record("ses_dismiss2", "fnd_dismiss_002")

      assert {:ok, _} = Tet.FindingStore.dismiss_finding("fnd_dismiss_002")

      assert {:error, :finding_already_dismissed} =
               Tet.FindingStore.dismiss_finding("fnd_dismiss_002")
    end

    test "rejects already promoted finding" do
      record("ses_dismiss3", "fnd_dismiss_003")

      assert {:ok, _} =
               Tet.FindingStore.promote_to_persistent_memory("fnd_dismiss_003")

      assert {:error, :finding_already_promoted} =
               Tet.FindingStore.dismiss_finding("fnd_dismiss_003")
    end
  end

  # ============================================================
  # Audit event builder tests
  # ============================================================

  describe "Tet.FindingStore audit event builders" do
    test "builds finding.created event" do
      {:ok, finding} = valid_finding_attrs() |> Tet.Finding.new()
      event = Tet.FindingStore.build_finding_created_event(finding)

      assert event.type == :"finding.created"
      assert event.payload.finding_id == "fnd_tomap"
      assert event.payload.source == :event
      assert event.session_id == "ses_001"
    end

    test "builds finding.promoted_to_persistent_memory event" do
      {:ok, finding} = valid_finding_attrs() |> Tet.Finding.new()

      {:ok, pm} =
        Tet.PersistentMemory.new(%{
          id: "pm_audit",
          session_id: "ses_001",
          title: "Audit PM",
          source_finding_id: "fnd_tomap"
        })

      event = Tet.FindingStore.build_promoted_to_persistent_memory_event(finding, pm)

      assert event.type == :"finding.promoted_to_persistent_memory"
      assert event.payload.finding_id == "fnd_tomap"
      assert event.payload.persistent_memory_id == "pm_audit"
    end

    test "builds finding.promoted_to_project_lesson event" do
      {:ok, finding} = valid_finding_attrs() |> Tet.Finding.new()

      {:ok, lesson} =
        Tet.ProjectLesson.new(%{
          id: "pl_audit",
          title: "Audit lesson",
          category: :convention,
          source_finding_id: "fnd_tomap"
        })

      event = Tet.FindingStore.build_promoted_to_project_lesson_event(finding, lesson)

      assert event.type == :"finding.promoted_to_project_lesson"
      assert event.payload.finding_id == "fnd_tomap"
      assert event.payload.project_lesson_id == "pl_audit"
      assert event.payload.category == :convention
    end

    test "builds finding.dismissed event" do
      {:ok, finding} = valid_finding_attrs() |> Tet.Finding.new()
      event = Tet.FindingStore.build_finding_dismissed_event(finding)

      assert event.type == :"finding.dismissed"
      assert event.payload.finding_id == "fnd_tomap"
    end
  end

  # ============================================================
  # Audit event emission tests (BD-0036 review fix)
  # ============================================================

  describe "audit event emission on store operations" do
    test "record_finding emits finding.created event" do
      Tet.Store.Memory.reset()

      assert {:ok, _finding} =
               Tet.FindingStore.record_finding(%{
                 id: "fnd_emit_created",
                 session_id: "ses_emit",
                 title: "Emit test",
                 source: :event,
                 severity: :warning
               })

      {:ok, events} = Tet.Store.Memory.list_events("ses_emit", [])
      created_events = Enum.filter(events, &(&1.type == :"finding.created"))
      assert length(created_events) == 1
      assert hd(created_events).payload["finding_id"] == "fnd_emit_created"
    end

    test "promote_to_persistent_memory emits finding.promoted_to_persistent_memory event" do
      Tet.Store.Memory.reset()

      record("ses_emit_pm", "fnd_emit_pm")

      assert {:ok, {_finding, _pm}} =
               Tet.FindingStore.promote_to_persistent_memory("fnd_emit_pm")

      {:ok, events} = Tet.Store.Memory.list_events("ses_emit_pm", [])

      promoted_events =
        Enum.filter(events, &(&1.type == :"finding.promoted_to_persistent_memory"))

      assert length(promoted_events) == 1
      assert hd(promoted_events).payload["finding_id"] == "fnd_emit_pm"
    end

    test "promote_to_project_lesson emits finding.promoted_to_project_lesson event" do
      Tet.Store.Memory.reset()

      record("ses_emit_pl", "fnd_emit_pl")

      assert {:ok, {_finding, _lesson}} =
               Tet.FindingStore.promote_to_project_lesson("fnd_emit_pl",
                 category: :convention
               )

      {:ok, events} = Tet.Store.Memory.list_events("ses_emit_pl", [])

      promoted_events =
        Enum.filter(events, &(&1.type == :"finding.promoted_to_project_lesson"))

      assert length(promoted_events) == 1
      assert hd(promoted_events).payload["finding_id"] == "fnd_emit_pl"
    end

    test "dismiss_finding emits finding.dismissed event" do
      Tet.Store.Memory.reset()

      record("ses_emit_dismiss", "fnd_emit_dismiss")

      assert {:ok, _dismissed} =
               Tet.FindingStore.dismiss_finding("fnd_emit_dismiss")

      {:ok, events} = Tet.Store.Memory.list_events("ses_emit_dismiss", [])
      dismissed_events = Enum.filter(events, &(&1.type == :"finding.dismissed"))
      assert length(dismissed_events) == 1
      assert hd(dismissed_events).payload["finding_id"] == "fnd_emit_dismiss"
    end
  end

  # ============================================================
  # Event type registration tests
  # ============================================================

  describe "Tet.Event finding store types" do
    test "finding store types are registered in known_types" do
      known = Tet.Event.known_types()

      assert :"finding.created" in known
      assert :"finding.promoted_to_persistent_memory" in known
      assert :"finding.promoted_to_project_lesson" in known
      assert :"finding.dismissed" in known
    end

    test "finding_store_types returns all four types" do
      types = Tet.Event.finding_store_types()

      assert :"finding.created" in types
      assert :"finding.promoted_to_persistent_memory" in types
      assert :"finding.promoted_to_project_lesson" in types
      assert :"finding.dismissed" in types
      assert length(types) == 4
    end

    test "event builders produce valid events" do
      event = Tet.Event.finding_created(%{finding_id: "f1", source: :event})
      assert {:ok, validated} = Tet.Event.new(Tet.Event.to_map(event))
      assert validated.type == :"finding.created"
    end
  end

  # ============================================================
  # Deprecated naming verification (AC5)
  # ============================================================

  describe "deprecated memory names" do
    test "no Bronze, Silver, or Gold atoms in core modules" do
      core_modules = [
        Tet.Finding,
        Tet.PersistentMemory,
        Tet.ProjectLesson,
        Tet.FindingStore,
        Tet.Event,
        Tet.Store,
        Tet.Core
      ]

      for mod <- core_modules do
        source = mod.__info__(:compile)[:source]

        if source do
          content = File.read!(List.to_string(source))

          # Check for deprecated tier names as atoms or strings
          refute String.contains?(content, ":Bronze"),
                 "Deprecated :Bronze found in #{mod}"

          refute String.contains?(content, ":Silver"),
                 "Deprecated :Silver found in #{mod}"

          refute String.contains?(content, ":Gold"),
                 "Deprecated :Gold found in #{mod}"
        end
      end
    end

    test "promotion targets use approved renamed terms" do
      targets = Tet.FindingStore.promotion_targets()

      assert :persistent_memory in targets
      assert :project_lesson in targets
      refute :bronze in targets
      refute :silver in targets
      refute :gold in targets
    end

    test "Tet.Core capabilities use approved terms" do
      caps = Tet.Core.capabilities()

      assert :finding_store in caps
      assert :persistent_memory in caps
      assert :project_lessons in caps
      refute :bronze in caps
      refute :silver in caps
      refute :gold in caps
    end
  end

  # ============================================================
  # Traceability and audit tests (AC1)
  # ============================================================

  describe "promotion traceability" do
    test "persistent memory entry preserves source_finding_id" do
      record("ses_trace_pm", "fnd_trace_pm")

      assert {:ok, {_, pm}} =
               Tet.FindingStore.promote_to_persistent_memory("fnd_trace_pm")

      assert pm.source_finding_id == "fnd_trace_pm"
    end

    test "project lesson preserves source_finding_id" do
      record("ses_trace_pl", "fnd_trace_pl")

      assert {:ok, {_, lesson}} =
               Tet.FindingStore.promote_to_project_lesson("fnd_trace_pl",
                 category: :error_pattern
               )

      assert lesson.source_finding_id == "fnd_trace_pl"
    end

    test "finding promoted_to tuple links back to target" do
      record("ses_trace_link", "fnd_trace_link")

      assert {:ok, {finding, pm}} =
               Tet.FindingStore.promote_to_persistent_memory("fnd_trace_link")

      assert finding.promoted_to == {:persistent_memory, pm.id}

      # Can follow the link to the actual entry
      assert {:ok, fetched_pm} = Tet.FindingStore.get_persistent_memory(pm.id)
      assert fetched_pm.id == pm.id
    end

    test "finding evidence_refs carry through to persistent memory" do
      assert {:ok, _} =
               Tet.FindingStore.record_finding(%{
                 id: "fnd_evidence",
                 session_id: "ses_evidence",
                 title: "With evidence",
                 source: :verifier,
                 evidence_refs: [
                   %{type: :event, id: "evt_001"},
                   %{type: :artifact, id: "art_001"}
                 ]
               })

      assert {:ok, {_, pm}} =
               Tet.FindingStore.promote_to_persistent_memory("fnd_evidence")

      assert pm.evidence_refs != nil
      assert length(pm.evidence_refs) == 2
    end
  end

  # ============================================================
  # Store Helpers tests for finding merge
  # ============================================================

  describe "Tet.Store.Helpers.merge_finding_attrs/2" do
    test "merges mutable fields and validates" do
      {:ok, finding} = valid_finding_attrs() |> Tet.Finding.new()

      assert {:ok, merged} =
               Tet.Store.Helpers.merge_finding_attrs(finding, %{
                 severity: :critical,
                 status: :promoted
               })

      assert merged.severity == :critical
      assert merged.status == :promoted
    end

    test "strips immutable fields" do
      {:ok, finding} = valid_finding_attrs() |> Tet.Finding.new()

      assert {:ok, merged} =
               Tet.Store.Helpers.merge_finding_attrs(finding, %{
                 id: "hacked",
                 session_id: "hacked",
                 severity: :critical
               })

      assert merged.id == "fnd_tomap"
      assert merged.session_id == "ses_001"
      assert merged.severity == :critical
    end
  end

  # ============================================================
  # Helpers
  # ============================================================

  defp valid_finding_attrs do
    %{
      id: "fnd_tomap",
      session_id: "ses_001",
      title: "Test finding",
      source: :event,
      severity: :warning
    }
  end

  defp record(session_id, finding_id) do
    Tet.FindingStore.record_finding(%{
      id: finding_id,
      session_id: session_id,
      title: "Test finding",
      source: :event,
      severity: :warning
    })
  end
end
