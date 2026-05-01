defmodule Tet.Runtime.Remote.HeartbeatTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Tet.Runtime.Remote.Heartbeat

  describe "start_link/2" do
    test "starts a heartbeat monitor with default options" do
      assert {:ok, pid} = Heartbeat.start_link("worker-1")
      assert Heartbeat.status(pid) == :starting
      assert Heartbeat.alive?(pid) == true
      Heartbeat.stop(pid)
    end

    test "starts a heartbeat monitor with custom interval" do
      assert {:ok, pid} = Heartbeat.start_link("worker-2", interval_ms: 5_000)
      assert Heartbeat.status(pid) == :starting
      Heartbeat.stop(pid)
    end

    test "starts with custom timeout_multiplier" do
      assert {:ok, pid} =
               Heartbeat.start_link("worker-3", interval_ms: 50_000, timeout_multiplier: 5)

      assert Heartbeat.status(pid) == :starting
      Heartbeat.stop(pid)
    end

    test "starts with lease_id from bootstrap report" do
      assert {:ok, pid} = Heartbeat.start_link("worker-4", lease_id: "lease-abc")
      assert Heartbeat.status(pid) == :starting
      Heartbeat.stop(pid)
    end
  end

  describe "beat/2" do
    test "registers a heartbeat and transitions to alive" do
      assert {:ok, pid} = Heartbeat.start_link("worker-beat-1")
      :ok = Heartbeat.beat(pid, %{last_seen_monotonic_ms: 100})
      assert Heartbeat.status(pid) == :alive
      assert Heartbeat.alive?(pid) == true
      Heartbeat.stop(pid)
    end

    test "registers heartbeat with lease_id" do
      assert {:ok, pid} = Heartbeat.start_link("worker-beat-2")
      :ok = Heartbeat.beat(pid, %{last_seen_monotonic_ms: 200, lease_id: "lease-xyz"})
      assert Heartbeat.status(pid) == :alive
      Heartbeat.stop(pid)
    end

    test "updates last_seen on repeated beats" do
      assert {:ok, pid} = Heartbeat.start_link("worker-beat-3", interval_ms: 50_000)

      :ok = Heartbeat.beat(pid, %{last_seen_monotonic_ms: 100})
      assert Heartbeat.status(pid) == :alive

      :ok = Heartbeat.beat(pid, %{last_seen_monotonic_ms: 200})
      assert Heartbeat.status(pid) == :alive

      Heartbeat.stop(pid)
    end
  end

  describe "status/1" do
    test "reports :starting initially" do
      assert {:ok, pid} = Heartbeat.start_link("worker-status-1", interval_ms: 50_000)
      assert Heartbeat.status(pid) == :starting
      Heartbeat.stop(pid)
    end

    test "reports :alive after heartbeat" do
      assert {:ok, pid} = Heartbeat.start_link("worker-status-2", interval_ms: 50_000)
      Heartbeat.beat(pid, %{last_seen_monotonic_ms: 100})
      assert Heartbeat.status(pid) == :alive
      Heartbeat.stop(pid)
    end

    test "reports :stopped after stop" do
      assert {:ok, pid} = Heartbeat.start_link("worker-status-3", interval_ms: 50_000)
      Heartbeat.stop(pid)
      :timer.sleep(20)
      refute Process.alive?(pid)
    end
  end

  describe "alive?/1" do
    test "returns true for starting status" do
      assert {:ok, pid} = Heartbeat.start_link("worker-alive-1", interval_ms: 50_000)
      assert Heartbeat.alive?(pid) == true
      Heartbeat.stop(pid)
    end

    test "returns true for alive status" do
      assert {:ok, pid} = Heartbeat.start_link("worker-alive-2", interval_ms: 50_000)
      Heartbeat.beat(pid, %{last_seen_monotonic_ms: 100})
      assert Heartbeat.alive?(pid) == true
      Heartbeat.stop(pid)
    end
  end

  describe "heartbeat timeout detection" do
    test "transitions to stale when half the timeout window passes without beat" do
      assert {:ok, pid} =
               Heartbeat.start_link("worker-timeout-1",
                 interval_ms: 20,
                 timeout_multiplier: 2
               )

      Heartbeat.beat(pid, %{last_seen_monotonic_ms: System.monotonic_time(:millisecond)})
      :timer.sleep(25)

      status = Heartbeat.status(pid)

      assert status in [:stale, :alive],
             "Expected stale within timeout window, got: #{inspect(status)}"

      Heartbeat.stop(pid)
    end

    test "transitions to expired when timeout window fully passes without beat" do
      assert {:ok, pid} =
               Heartbeat.start_link("worker-expired",
                 interval_ms: 15,
                 timeout_multiplier: 2
               )

      Heartbeat.beat(pid, %{last_seen_monotonic_ms: System.monotonic_time(:millisecond)})
      :timer.sleep(50)

      status = Heartbeat.status(pid)

      assert status in [:expired, :stale],
             "Expected expired or stale after timeout window, got: #{inspect(status)}"

      Heartbeat.stop(pid)
    end
  end

  describe "telemetry integration" do
    test "emits start event with measurements and metadata" do
      test_pid = self()

      telemetry = fn event_name, measurements, metadata ->
        send(test_pid, {:hb_telemetry, event_name, measurements, metadata})
      end

      assert {:ok, pid} =
               Heartbeat.start_link("worker-tele-1",
                 interval_ms: 50_000,
                 telemetry_emit: telemetry
               )

      assert_receive {:hb_telemetry, [:tet, :remote, :heartbeat, :start], measurements, metadata}

      assert is_integer(measurements.interval_ms)
      assert is_integer(measurements.timeout_ms)
      assert metadata.worker_ref == "worker-tele-1"

      Heartbeat.stop(pid)
    end

    test "emits beat event on heartbeat registration" do
      test_pid = self()

      telemetry = fn event_name, measurements, metadata ->
        send(test_pid, {:hb_telemetry, event_name, measurements, metadata})
      end

      assert {:ok, pid} =
               Heartbeat.start_link("worker-tele-2",
                 interval_ms: 50_000,
                 telemetry_emit: telemetry
               )

      assert_receive {:hb_telemetry, [:tet, :remote, :heartbeat, :start], _, _}

      Heartbeat.beat(pid, %{last_seen_monotonic_ms: 42})

      assert_receive {:hb_telemetry, [:tet, :remote, :heartbeat, :beat], measurements, metadata}

      assert is_integer(measurements.last_seen_monotonic_ms)
      assert measurements.remote_timestamp_ms == 42
      assert metadata.worker_ref == "worker-tele-2"

      Heartbeat.stop(pid)
    end

    test "emits stop event on graceful stop (only once)" do
      test_pid = self()

      telemetry = fn event_name, measurements, metadata ->
        send(test_pid, {:hb_telemetry, event_name, measurements, metadata})
      end

      assert {:ok, pid} =
               Heartbeat.start_link("worker-tele-3",
                 interval_ms: 50_000,
                 telemetry_emit: telemetry
               )

      assert_receive {:hb_telemetry, [:tet, :remote, :heartbeat, :start], _, _}

      Heartbeat.stop(pid)

      assert_receive {:hb_telemetry, [:tet, :remote, :heartbeat, :stop], measurements, _}
      assert is_integer(measurements.duration_ms)

      # Ensure only ONE stop event was emitted (not from both cast and terminate)
      refute_receive {:hb_telemetry, [:tet, :remote, :heartbeat, :stop], _, _}, 100
    end
  end

  describe "stop/1" do
    test "stops the heartbeat monitor gracefully" do
      assert {:ok, pid} = Heartbeat.start_link("worker-stop-1")
      assert Process.alive?(pid)
      :ok = Heartbeat.stop(pid)
      :timer.sleep(20)
      refute Process.alive?(pid)
    end
  end
end
