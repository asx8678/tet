defmodule Tet.Patch.SnapshotTest do
  use ExUnit.Case, async: true

  alias Tet.Patch.Snapshot

  describe "pre_apply/2" do
    test "creates a pre-apply snapshot with correct hash" do
      content = "defmodule Test do\nend\n"
      snapshot = Snapshot.pre_apply("lib/test.ex", content)

      assert snapshot.file_path == "lib/test.ex"
      assert snapshot.content == content
      assert snapshot.captured_at == :pre_apply
      assert snapshot.byte_size == byte_size(content)
      assert snapshot.content_hash == Snapshot.hash_content(content)
    end

    test "creates consistent hashes for same content" do
      content = "same content"
      hash1 = Snapshot.pre_apply("f1.ex", content).content_hash
      hash2 = Snapshot.pre_apply("f2.ex", content).content_hash

      assert hash1 == hash2
    end

    test "creates different hashes for different content" do
      hash1 = Snapshot.pre_apply("f.ex", "content a").content_hash
      hash2 = Snapshot.pre_apply("f.ex", "content b").content_hash

      refute hash1 == hash2
    end
  end

  describe "post_apply/2" do
    test "creates a post-apply snapshot" do
      content = "updated content"
      snapshot = Snapshot.post_apply("lib/test.ex", content)

      assert snapshot.file_path == "lib/test.ex"
      assert snapshot.content == content
      assert snapshot.captured_at == :post_apply
    end
  end

  describe "hash_content/1" do
    test "returns sha256 hex string" do
      hash = Snapshot.hash_content("hello")
      assert String.match?(hash, ~r/^[a-f0-9]{64}$/)

      expected =
        :crypto.hash(:sha256, "hello") |> Base.encode16(case: :lower)

      assert hash == expected
    end

    test "returns consistent results" do
      assert Snapshot.hash_content("test") == Snapshot.hash_content("test")
    end
  end

  describe "to_map/1" do
    test "converts to JSON-friendly map" do
      snapshot = Snapshot.pre_apply("lib/test.ex", "content")
      map = Snapshot.to_map(snapshot)

      assert map["file_path"] == "lib/test.ex"
      assert map["content_hash"] == snapshot.content_hash
      assert map["captured_at"] == "pre_apply"
      assert map["byte_size"] == 7
      assert map["content"] == "content"
    end
  end
end
