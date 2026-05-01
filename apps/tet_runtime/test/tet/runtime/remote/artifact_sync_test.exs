defmodule Tet.Runtime.Remote.ArtifactSyncTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Tet.Runtime.Remote.ArtifactSync
  alias Tet.Runtime.Remote.Request

  defmodule FakeArtifactTransport do
    @behaviour Tet.Runtime.Remote.Transport

    def bootstrap(%Request{} = _request, _opts), do: {:ok, %{status: :ready}}
    def install(%Request{} = _request, _opts), do: {:ok, %{status: :installed}}
    def check(%Request{} = _request, _opts), do: {:ok, %{status: :checked}}

    def fetch_artifact(_request, _path, opts) do
      content = Keyword.get(opts, :artifact_content, "default artifact content")
      {:ok, content}
    end
  end

  defmodule FakeErrorTransport do
    @behaviour Tet.Runtime.Remote.Transport

    def bootstrap(%Request{} = _request, _opts), do: {:ok, %{status: :ready}}
    def install(%Request{} = _request, _opts), do: {:ok, %{status: :installed}}
    def check(%Request{} = _request, _opts), do: {:ok, %{status: :checked}}

    def fetch_artifact(_request, _path, _opts) do
      {:error, :artifact_not_found}
    end
  end

  defmodule FakeRaisingTransport do
    @behaviour Tet.Runtime.Remote.Transport

    def bootstrap(%Request{} = _request, _opts), do: {:ok, %{status: :ready}}
    def install(%Request{} = _request, _opts), do: {:ok, %{status: :installed}}
    def check(%Request{} = _request, _opts), do: {:ok, %{status: :checked}}

    def fetch_artifact(_request, _path, _opts) do
      raise "artifact fetch boom"
    end
  end

  defmodule MissingFetchTransport do
    @behaviour Tet.Runtime.Remote.Transport

    def bootstrap(%Request{} = _request, _opts), do: {:ok, %{status: :ready}}
    def install(%Request{} = _request, _opts), do: {:ok, %{status: :installed}}
    def check(%Request{} = _request, _opts), do: {:ok, %{status: :checked}}
  end

  describe "fetch/3" do
    test "fetches artifact from remote worker successfully" do
      content = "hello artifact world"

      assert {:ok, result} =
               ArtifactSync.fetch("worker-art-1", "/tmp/build/output.bin",
                 transport: FakeArtifactTransport,
                 transport_opts: [artifact_content: content]
               )

      assert result.path == "/tmp/build/output.bin"
      assert result.size == byte_size(content)
      assert result.verified? == true
      assert is_binary(result.checksum)
    end

    test "verifies checksum when expected checksum is provided" do
      content = "data with expected checksum"
      expected = ArtifactSync.checksum(content)

      assert {:ok, result} =
               ArtifactSync.fetch("worker-art-2", "/tmp/build/output2.bin",
                 transport: FakeArtifactTransport,
                 transport_opts: [artifact_content: content],
                 expected_checksum: expected
               )

      assert result.verified? == true
      assert result.checksum == expected
    end

    test "reports checksum_mismatch with actual computed checksum" do
      content = "data with wrong checksum"
      actual = ArtifactSync.checksum(content)

      assert {:error, {:checksum_mismatch, "badchecksum123", ^actual}} =
               ArtifactSync.fetch("worker-art-3", "/tmp/build/output3.bin",
                 transport: FakeArtifactTransport,
                 transport_opts: [artifact_content: content],
                 expected_checksum: "badchecksum123"
               )
    end

    test "returns error when transport returns error" do
      assert {:error, :artifact_not_found} =
               ArtifactSync.fetch("worker-art-4", "/tmp/build/missing.bin",
                 transport: FakeErrorTransport,
                 transport_opts: []
               )
    end

    test "returns error when transport raises" do
      assert {:error, {:artifact_transport_failed, RuntimeError}} =
               ArtifactSync.fetch("worker-art-5", "/tmp/build/boom.bin",
                 transport: FakeRaisingTransport,
                 transport_opts: []
               )
    end

    test "returns error when transport does not implement fetch_artifact" do
      assert {:error, {:artifact_transport_missing_callback, MissingFetchTransport}} =
               ArtifactSync.fetch("worker-art-6", "/tmp/build/missing_cb.bin",
                 transport: MissingFetchTransport,
                 transport_opts: []
               )
    end

    test "returns error when transport is not configured" do
      assert {:error, :artifact_transport_not_configured} =
               ArtifactSync.fetch("worker-art-7", "/tmp/build/no_transport.bin")
    end

    test "returns error when transport is not a module" do
      assert {:error, {:invalid_artifact_transport, :not_a_module}} =
               ArtifactSync.fetch("worker-art-8", "/tmp/build/bad_transport.bin",
                 transport: "not_a_module",
                 transport_opts: []
               )
    end

    test "returns error when transport_opts is not a keyword" do
      assert {:error, {:invalid_artifact_transport_opts, :not_a_keyword}} =
               ArtifactSync.fetch("worker-art-9", "/tmp/build/bad_opts.bin",
                 transport: FakeArtifactTransport,
                 transport_opts: %{bad: true}
               )
    end

    test "accepts a full Request struct as first argument" do
      request = %Request{
        operation: :check,
        worker_ref: "worker-art-req",
        profile_alias: "profile-art-req",
        protocol_version: "tet.remote.bootstrap.v1",
        release_version: "0.1.0",
        capabilities: %{},
        sandbox: %{},
        heartbeat: %{},
        secret_refs: [],
        metadata: %{}
      }

      assert {:ok, result} =
               ArtifactSync.fetch(request, "/tmp/build/from_request.bin",
                 transport: FakeArtifactTransport,
                 transport_opts: [artifact_content: "from request"]
               )

      assert result.size == 12
    end

    test "writes artifact to destination path when provided" do
      tmp_dir = System.tmp_dir!()
      dest = Path.join(tmp_dir, "tet_artifact_test_#{:erlang.unique_integer([:positive])}.bin")
      content = "write me to disk"

      assert {:ok, _result} =
               ArtifactSync.fetch("worker-art-dest", "/tmp/build/dest.bin",
                 transport: FakeArtifactTransport,
                 transport_opts: [artifact_content: content],
                 destination: dest
               )

      assert File.exists?(dest)
      assert File.read!(dest) == content

      File.rm!(dest)
    end
  end

  describe "checksum/1" do
    test "computes SHA-256 hex checksum of a binary" do
      assert ArtifactSync.checksum("hello") ==
               "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"

      assert ArtifactSync.checksum("") ==
               "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    end

    test "produces consistent checksums for same input" do
      data = "consistent data input"
      assert ArtifactSync.checksum(data) == ArtifactSync.checksum(data)
    end

    test "produces different checksums for different inputs" do
      refute ArtifactSync.checksum("data_a") == ArtifactSync.checksum("data_b")
    end
  end

  describe "verify/2" do
    test "returns :ok when checksums match" do
      data = "verify me please"
      checksum = ArtifactSync.checksum(data)
      assert ArtifactSync.verify(data, checksum) == :ok
    end

    test "returns error tuple with actual computed checksum" do
      data = "verify me please"
      actual = ArtifactSync.checksum(data)

      assert {:error, {:checksum_mismatch, "badchecksum", ^actual}} =
               ArtifactSync.verify(data, "badchecksum")
    end
  end

  describe "chunk/2" do
    test "chunks binary into specified chunk sizes" do
      data = String.duplicate("A", 100_000)
      chunks = ArtifactSync.chunk(data, 32_768)

      assert length(chunks) == 4
      assert byte_size(Enum.at(chunks, 0)) == 32_768
      assert byte_size(Enum.at(chunks, 1)) == 32_768
      assert byte_size(Enum.at(chunks, 2)) == 32_768
      assert byte_size(Enum.at(chunks, 3)) == 1_696
    end

    test "returns single chunk for data smaller than chunk_size" do
      chunks = ArtifactSync.chunk("small", 65_536)
      assert length(chunks) == 1
      assert chunks == ["small"]
    end

    test "returns empty list for empty data" do
      chunks = ArtifactSync.chunk("", 65_536)
      assert chunks == []
    end
  end

  describe "merge/1" do
    test "merges list of chunks back into single binary" do
      chunks = ["hello ", "world", "!"]
      assert ArtifactSync.merge(chunks) == "hello world!"
    end

    test "empty list produces empty binary" do
      assert ArtifactSync.merge([]) == ""
    end
  end

  describe "verify_chunks/2" do
    test "verifies merged chunks against expected checksum" do
      chunks = ["chunk1", "chunk2", "chunk3"]
      merged = ArtifactSync.merge(chunks)
      checksum = ArtifactSync.checksum(merged)

      assert ArtifactSync.verify_chunks(chunks, checksum) == :ok
    end

    test "returns error on checksum mismatch for merged chunks" do
      chunks = ["chunk1", "chunk2", "chunk3"]

      assert {:error, {:checksum_mismatch, "badchecksum", _computed}} =
               ArtifactSync.verify_chunks(chunks, "badchecksum")
    end
  end

  describe "telemetry integration" do
    test "emits start and complete telemetry events on successful fetch" do
      telemetry = fn event_name, measurements, metadata ->
        send(self(), {:artifact_telemetry, event_name, measurements, metadata})
      end

      assert {:ok, _result} =
               ArtifactSync.fetch("worker-tele-art", "/tmp/build/tele.bin",
                 transport: FakeArtifactTransport,
                 transport_opts: [artifact_content: "telemetry test data"],
                 telemetry_emit: telemetry
               )

      assert_receive {:artifact_telemetry, [:tet, :remote, :artifact, :start], _, start_meta}
      assert start_meta.worker_ref == "worker-tele-art"
      assert start_meta.path == "/tmp/build/tele.bin"

      assert_receive {:artifact_telemetry, [:tet, :remote, :artifact, :complete], meas, meta}
      assert meas.size == 19
      assert is_binary(meta.checksum)
    end

    test "emits error telemetry event on fetch failure" do
      telemetry = fn event_name, measurements, metadata ->
        send(self(), {:artifact_telemetry, event_name, measurements, metadata})
      end

      ArtifactSync.fetch("worker-tele-err", "/tmp/build/err.bin",
        transport: FakeErrorTransport,
        transport_opts: [],
        telemetry_emit: telemetry
      )

      assert_receive {:artifact_telemetry, [:tet, :remote, :artifact, :start], _, _}
      assert_receive {:artifact_telemetry, [:tet, :remote, :artifact, :error], _, _}
    end
  end
end
