defmodule Tet.Runtime.Remote.CancelTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Tet.Runtime.Remote.Cancel
  alias Tet.Runtime.Remote.Request

  defmodule FakeCancelTransport do
    @behaviour Tet.Runtime.Remote.Transport

    def bootstrap(%Request{} = _request, _opts), do: {:ok, %{status: :ready}}
    def install(%Request{} = _request, _opts), do: {:ok, %{status: :installed}}
    def check(%Request{} = _request, _opts), do: {:ok, %{status: :checked}}

    def cancel(cancel_payload, opts) do
      if test_pid = Keyword.get(opts, :test_pid) do
        send(test_pid, {:cancel_payload, cancel_payload})
      end

      {:ok, %{status: :cancelled, acknowledged_at: System.monotonic_time(:millisecond)}}
    end
  end

  defmodule FakeSlowCancelTransport do
    @behaviour Tet.Runtime.Remote.Transport

    def bootstrap(%Request{} = _request, _opts), do: {:ok, %{status: :ready}}
    def install(%Request{} = _request, _opts), do: {:ok, %{status: :installed}}
    def check(%Request{} = _request, _opts), do: {:ok, %{status: :checked}}

    def cancel(_cancel_payload, _opts) do
      :timer.sleep(500)
      {:ok, %{status: :cancelled, acknowledged_at: System.monotonic_time(:millisecond)}}
    end
  end

  defmodule FakeErrorTransport do
    @behaviour Tet.Runtime.Remote.Transport

    def bootstrap(%Request{} = _request, _opts), do: {:ok, %{status: :ready}}
    def install(%Request{} = _request, _opts), do: {:ok, %{status: :installed}}
    def check(%Request{} = _request, _opts), do: {:ok, %{status: :checked}}

    def cancel(_cancel_payload, _opts) do
      {:error, :cancel_rejected}
    end
  end

  defmodule FakeRaisingTransport do
    @behaviour Tet.Runtime.Remote.Transport

    def bootstrap(%Request{} = _request, _opts), do: {:ok, %{status: :ready}}
    def install(%Request{} = _request, _opts), do: {:ok, %{status: :installed}}
    def check(%Request{} = _request, _opts), do: {:ok, %{status: :checked}}

    def cancel(_cancel_payload, _opts) do
      raise "cancel boom"
    end
  end

  defmodule MissingCancelTransport do
    @behaviour Tet.Runtime.Remote.Transport

    def bootstrap(%Request{} = _request, _opts), do: {:ok, %{status: :ready}}
    def install(%Request{} = _request, _opts), do: {:ok, %{status: :installed}}
    def check(%Request{} = _request, _opts), do: {:ok, %{status: :checked}}
  end

  describe "cancel/2" do
    test "sends cancellation and receives acknowledgment" do
      assert {:ok, ack} =
               Cancel.cancel("worker-cancel-1",
                 transport: FakeCancelTransport,
                 transport_opts: []
               )

      assert ack.status == :cancelled
      assert is_integer(ack.acknowledged_at)
    end

    test "accepts a full Request struct as first argument" do
      request = %Request{
        operation: :check,
        worker_ref: "worker-cancel-req",
        profile_alias: "profile-cancel-req",
        protocol_version: "tet.remote.bootstrap.v1",
        release_version: "0.1.0",
        capabilities: %{},
        sandbox: %{},
        heartbeat: %{},
        secret_refs: [],
        metadata: %{}
      }

      assert {:ok, ack} =
               Cancel.cancel(request,
                 transport: FakeCancelTransport,
                 transport_opts: []
               )

      assert ack.status == :cancelled
    end

    test "sends cancel payload with expected shape" do
      assert {:ok, _ack} =
               Cancel.cancel("worker-payload-shape",
                 transport: FakeCancelTransport,
                 transport_opts: [test_pid: self()],
                 reason: "user_initiated",
                 lease_id: "lease-123",
                 metadata: %{custom_key: "custom_val"}
               )

      assert_receive {:cancel_payload, payload}
      assert payload.operation == :cancel
      assert payload.worker_ref == "worker-payload-shape"
      assert payload.reason == "user_initiated"
      assert is_map(payload.metadata)
      assert is_integer(payload.metadata.sent_at_monotonic_ms)
    end

    test "includes optional reason in cancellation payload" do
      assert {:ok, _ack} =
               Cancel.cancel("worker-reason",
                 transport: FakeCancelTransport,
                 transport_opts: [],
                 reason: "user_initiated"
               )
    end

    test "times out when worker does not acknowledge in time" do
      assert {:error, :cancel_timeout} =
               Cancel.cancel("worker-timeout",
                 transport: FakeSlowCancelTransport,
                 transport_opts: [],
                 timeout_ms: 50
               )
    end

    test "returns error when transport rejects cancellation" do
      assert {:error, :cancel_rejected} =
               Cancel.cancel("worker-reject",
                 transport: FakeErrorTransport,
                 transport_opts: []
               )
    end

    test "returns error when transport module raises" do
      assert {:error, {:cancel_transport_failed, RuntimeError}} =
               Cancel.cancel("worker-raise",
                 transport: FakeRaisingTransport,
                 transport_opts: []
               )
    end

    test "returns error when transport does not implement cancel" do
      assert {:error, {:cancel_transport_missing_callback, MissingCancelTransport}} =
               Cancel.cancel("worker-missing",
                 transport: MissingCancelTransport,
                 transport_opts: []
               )
    end

    test "returns error when transport is not configured" do
      assert {:error, :cancel_transport_not_configured} =
               Cancel.cancel("worker-no-transport")
    end

    test "returns error when transport is not a module" do
      assert {:error, {:invalid_cancel_transport, :not_a_module}} =
               Cancel.cancel("worker-bad-transport",
                 transport: "not_a_module",
                 transport_opts: []
               )
    end

    test "returns error when transport_opts is not a keyword" do
      assert {:error, {:invalid_cancel_transport_opts, :not_a_keyword}} =
               Cancel.cancel("worker-bad-opts",
                 transport: FakeCancelTransport,
                 transport_opts: %{bad: true}
               )
    end
  end

  describe "cancel_raw/2" do
    test "delegates to cancel with worker_ref as binary" do
      assert {:ok, ack} =
               Cancel.cancel_raw("worker-raw-1",
                 transport: FakeCancelTransport,
                 transport_opts: []
               )

      assert ack.status == :cancelled
    end
  end

  describe "telemetry integration" do
    test "emits start and ack telemetry events on successful cancel" do
      telemetry = fn event_name, measurements, metadata ->
        send(self(), {:cancel_telemetry, event_name, measurements, metadata})
      end

      assert {:ok, _ack} =
               Cancel.cancel("worker-tele-ok",
                 transport: FakeCancelTransport,
                 transport_opts: [],
                 telemetry_emit: telemetry
               )

      assert_receive {:cancel_telemetry, [:tet, :remote, :cancel, :start], _, start_meta}
      assert start_meta.worker_ref == "worker-tele-ok"

      assert_receive {:cancel_telemetry, [:tet, :remote, :cancel, :ack], ack_meas, _ack_meta}
      assert is_integer(ack_meas.duration_ms)
    end

    test "emits timeout telemetry event on cancel timeout" do
      telemetry = fn event_name, measurements, metadata ->
        send(self(), {:cancel_telemetry, event_name, measurements, metadata})
      end

      Cancel.cancel("worker-tele-timeout",
        transport: FakeSlowCancelTransport,
        transport_opts: [],
        timeout_ms: 50,
        telemetry_emit: telemetry
      )

      assert_receive {:cancel_telemetry, [:tet, :remote, :cancel, :start], _, _}
      assert_receive {:cancel_telemetry, [:tet, :remote, :cancel, :timeout], meas, _}
      assert is_integer(meas.duration_ms)
    end

    test "emits error telemetry event on cancel error" do
      telemetry = fn event_name, measurements, metadata ->
        send(self(), {:cancel_telemetry, event_name, measurements, metadata})
      end

      Cancel.cancel("worker-tele-error",
        transport: FakeErrorTransport,
        transport_opts: [],
        telemetry_emit: telemetry
      )

      assert_receive {:cancel_telemetry, [:tet, :remote, :cancel, :start], _, _}
      assert_receive {:cancel_telemetry, [:tet, :remote, :cancel, :error], _, _}
    end
  end
end
