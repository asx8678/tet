defmodule Tet.Steering.GuidanceStoreTest do
  use ExUnit.Case, async: true

  alias Tet.Steering.{GuidanceMessage, GuidanceStore}

  defp build_msg(attrs) do
    defaults = [decision_type: :guide, message: "Test guidance"]
    attrs = Keyword.merge(defaults, attrs)
    GuidanceMessage.new!(Map.new(attrs))
  end

  describe "new/0" do
    test "returns an empty map" do
      assert GuidanceStore.new() == %{}
    end
  end

  describe "add/2" do
    test "adds a message to the store" do
      msg = build_msg(id: "msg-1")
      store = GuidanceStore.new() |> GuidanceStore.add(msg)
      assert GuidanceStore.count(store) == 1
    end

    test "replaces a message with the same id" do
      msg1 = build_msg(id: "msg-1", message: "First")
      msg2 = build_msg(id: "msg-1", message: "Second")

      store =
        GuidanceStore.new()
        |> GuidanceStore.add(msg1)
        |> GuidanceStore.add(msg2)

      assert GuidanceStore.count(store) == 1
      assert hd(GuidanceStore.all(store)).message == "Second"
    end
  end

  describe "expire_by_session/2" do
    test "expires only messages for the given session" do
      msg_ses_a = build_msg(id: "m1", session_id: "ses_a", message: "Session A")
      msg_ses_b = build_msg(id: "m2", session_id: "ses_b", message: "Session B")

      store =
        GuidanceStore.new()
        |> GuidanceStore.add(msg_ses_a)
        |> GuidanceStore.add(msg_ses_b)
        |> GuidanceStore.expire_by_session("ses_a")

      assert GuidanceStore.active(store) |> length() == 1
      assert hd(GuidanceStore.active(store)).id == "m2"
    end

    test "leaves already-expired messages unchanged" do
      msg1 = build_msg(id: "m1", session_id: "ses_a", message: "Active")
      msg2 = build_msg(id: "m2", session_id: "ses_a", message: "Already expired", expired: true)

      store =
        GuidanceStore.new()
        |> GuidanceStore.add(msg1)
        |> GuidanceStore.add(msg2)
        |> GuidanceStore.expire_by_session("ses_a")

      assert GuidanceStore.active_count(store) == 0

      [m1, m2] = GuidanceStore.all(store) |> Enum.sort_by(& &1.id)
      assert m1.expired == true
      assert m2.expired == true
    end

    test "is idempotent" do
      msg = build_msg(id: "m1", session_id: "ses_a")

      store =
        GuidanceStore.new()
        |> GuidanceStore.add(msg)
        |> GuidanceStore.expire_by_session("ses_a")
        |> GuidanceStore.expire_by_session("ses_a")

      assert GuidanceStore.active_count(store) == 0
    end

    test "session isolation: other sessions are not expired" do
      ses_a = build_msg(id: "a1", session_id: "ses_a", message: "A active")
      ses_b = build_msg(id: "b1", session_id: "ses_b", message: "B active")
      ses_c = build_msg(id: "c1", session_id: "ses_c", message: "C active")

      store =
        GuidanceStore.new()
        |> GuidanceStore.add(ses_a)
        |> GuidanceStore.add(ses_b)
        |> GuidanceStore.add(ses_c)
        |> GuidanceStore.expire_by_session("ses_b")

      # Only ses_b got expired
      active = GuidanceStore.active(store)
      assert length(active) == 2
      active_ids = Enum.map(active, & &1.id) |> Enum.sort()
      assert active_ids == ["a1", "c1"]
    end
  end

  describe "active/1" do
    test "returns only non-expired messages" do
      active = build_msg(id: "a1", message: "Active")
      expired = build_msg(id: "e1", message: "Expired", expired: true)

      store =
        GuidanceStore.new()
        |> GuidanceStore.add(active)
        |> GuidanceStore.add(expired)

      result = GuidanceStore.active(store)
      assert length(result) == 1
      assert hd(result).id == "a1"
    end

    test "returns empty list when all are expired" do
      msg = build_msg(id: "m1", expired: true)
      store = GuidanceStore.new() |> GuidanceStore.add(msg)
      assert GuidanceStore.active(store) == []
    end

    test "returns empty list when store is empty" do
      assert GuidanceStore.active(GuidanceStore.new()) == []
    end
  end

  describe "by_session/1" do
    test "filters messages by session_id" do
      s1 = build_msg(id: "m1", session_id: "ses_a")
      s2 = build_msg(id: "m2", session_id: "ses_b")
      s3 = build_msg(id: "m3", session_id: "ses_a")

      store =
        GuidanceStore.new()
        |> GuidanceStore.add(s1)
        |> GuidanceStore.add(s2)
        |> GuidanceStore.add(s3)

      result = GuidanceStore.by_session(store, "ses_a")
      assert length(result) == 2
    end
  end

  describe "active_by_session/2" do
    test "returns only active messages for a session" do
      s1 = build_msg(id: "m1", session_id: "ses_a")
      s2 = build_msg(id: "m2", session_id: "ses_a", expired: true)

      store =
        GuidanceStore.new()
        |> GuidanceStore.add(s1)
        |> GuidanceStore.add(s2)

      result = GuidanceStore.active_by_session(store, "ses_a")
      assert length(result) == 1
      assert hd(result).id == "m1"
    end
  end

  describe "count/1 and active_count/1" do
    test "count/1 returns total messages" do
      store =
        GuidanceStore.new()
        |> GuidanceStore.add(build_msg(id: "m1"))
        |> GuidanceStore.add(build_msg(id: "m2"))

      assert GuidanceStore.count(store) == 2
    end

    test "active_count/1 returns only active messages" do
      store =
        GuidanceStore.new()
        |> GuidanceStore.add(build_msg(id: "m1"))
        |> GuidanceStore.add(build_msg(id: "m2", expired: true))

      assert GuidanceStore.active_count(store) == 1
    end
  end

  describe "serialization" do
    test "to_list/1 and from_list/1 roundtrip" do
      msg1 = build_msg(id: "m1", session_id: "ses_1", decision_type: :focus, message: "Focus!")
      msg2 = build_msg(id: "m2", session_id: "ses_1", message: "Guide.")

      store =
        GuidanceStore.new()
        |> GuidanceStore.add(msg1)
        |> GuidanceStore.add(msg2)

      list = GuidanceStore.to_list(store)
      assert length(list) == 2

      assert {:ok, restored} = GuidanceStore.from_list(list)
      assert GuidanceStore.count(restored) == 2
      assert length(GuidanceStore.active(restored)) == 2
    end

    test "from_list/1 returns error on invalid entry" do
      assert {:error, _} = GuidanceStore.from_list([%{decision_type: :invalid}])
    end
  end
end
