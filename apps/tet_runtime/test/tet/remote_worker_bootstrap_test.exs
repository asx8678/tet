defmodule Tet.RemoteWorkerBootstrapTest do
  use ExUnit.Case, async: false

  alias Tet.Runtime.Remote.Protocol
  alias Tet.Runtime.Remote.Request

  defmodule FakeTransport do
    @behaviour Tet.Runtime.Remote.Transport

    def bootstrap(%Request{} = request, opts), do: {:ok, report(request, :bootstrap, opts)}
    def install(%Request{} = request, opts), do: {:ok, report(request, :install, opts)}
    def check(%Request{} = request, opts), do: {:ok, report(request, :check, opts)}

    defp report(request, operation, opts) do
      if pid = Keyword.get(opts, :test_pid) do
        send(pid, {:fake_remote_request, operation, request})
      end

      %{
        status: status(operation),
        worker_ref: request.worker_ref,
        profile_alias: request.profile_alias,
        protocol_version: Protocol.supported_protocol_version(),
        release_version: request.release_version,
        capabilities: %{
          "commands" => ["test", "build", "test"],
          verifiers: %{enabled: true, entries: [:unit, "format", "unit"]},
          artifacts: true,
          cancel: "true",
          heartbeat: true
        },
        sandbox: %{
          workdir: request.sandbox.workdir,
          profile: "workspace_write",
          network: "disabled",
          policy: %{
            filesystem: "scoped_workdir",
            environment: "scrubbed",
            secrets: "scoped_refs_only"
          }
        },
        heartbeat: %{
          lease_id: "lease-#{request.profile_alias}",
          interval_ms: request.heartbeat.interval_ms,
          status: "alive",
          last_seen_ms: 42
        },
        metadata: metadata(opts)
      }
    end

    defp status(:bootstrap), do: :ready
    defp status(:install), do: :installed
    defp status(:check), do: :checked

    defp metadata(opts) do
      if Keyword.get(opts, :inject_raw_report_fields?) do
        %{
          transport: "fake",
          password: "super-secret-password",
          nested: %{api_key: "raw-api-key", secret_ref: "secret://worker/safe"}
        }
      else
        %{transport: "fake"}
      end
    end
  end

  defmodule BadProtocolTransport do
    @behaviour Tet.Runtime.Remote.Transport

    def bootstrap(%Request{} = request, _opts) do
      {:ok,
       FakeTransport.bootstrap(request, [])
       |> elem(1)
       |> Map.put(:protocol_version, "tet.remote.bootstrap.v0")}
    end

    def install(%Request{} = request, opts), do: bootstrap(request, opts)
    def check(%Request{} = request, opts), do: bootstrap(request, opts)
  end

  defmodule ReportMutationTransport do
    @behaviour Tet.Runtime.Remote.Transport

    def bootstrap(%Request{} = request, opts), do: mutate(request, :bootstrap, opts)
    def install(%Request{} = request, opts), do: mutate(request, :install, opts)
    def check(%Request{} = request, opts), do: mutate(request, :check, opts)

    defp mutate(request, operation, opts) do
      {:ok, report} = apply(FakeTransport, operation, [request, []])

      report =
        opts
        |> Keyword.get(:delete_report, [])
        |> Enum.reduce(report, fn key, acc -> Map.delete(acc, key) end)

      report =
        opts
        |> Keyword.get(:put_report, [])
        |> Enum.reduce(report, fn {key, value}, acc -> Map.put(acc, key, value) end)

      {:ok, report}
    end
  end

  defmodule NoHeartbeatTransport do
    @behaviour Tet.Runtime.Remote.Transport

    def bootstrap(%Request{} = request, _opts) do
      {:ok,
       FakeTransport.bootstrap(request, [])
       |> elem(1)
       |> Map.put(:capabilities, %{commands: true, verifiers: true, artifacts: true, cancel: true})}
    end

    def install(%Request{} = request, opts), do: bootstrap(request, opts)
    def check(%Request{} = request, opts), do: bootstrap(request, opts)
  end

  defmodule ErrorTransport do
    @behaviour Tet.Runtime.Remote.Transport

    def bootstrap(%Request{}, _opts) do
      {:error,
       %{
         authorization: "Bearer sk-remoteleak123",
         message: "worker failed with api_key=sk-remoteleak456"
       }}
    end

    def install(%Request{} = request, opts), do: bootstrap(request, opts)
    def check(%Request{} = request, opts), do: bootstrap(request, opts)
  end

  defmodule BadShapeTransport do
    @behaviour Tet.Runtime.Remote.Transport

    def bootstrap(%Request{}, _opts), do: {:ok, "not a report map"}
    def install(%Request{} = request, opts), do: bootstrap(request, opts)
    def check(%Request{} = request, opts), do: bootstrap(request, opts)
  end

  defmodule RaisingTransport do
    @behaviour Tet.Runtime.Remote.Transport

    def bootstrap(%Request{}, _opts), do: raise("boom with sk-remoteleak999")
    def install(%Request{} = request, opts), do: bootstrap(request, opts)
    def check(%Request{} = request, opts), do: bootstrap(request, opts)
  end

  defmodule MissingCheckTransport do
    def bootstrap(%Request{} = request, opts), do: FakeTransport.bootstrap(request, opts)
    def install(%Request{} = request, opts), do: FakeTransport.install(request, opts)
  end

  test "bootstrap_remote_worker reports version, capabilities, sandbox, and heartbeat" do
    assert {:ok, report} =
             Tet.bootstrap_remote_worker("vps-dev",
               transport: FakeTransport,
               transport_opts: [test_pid: self()],
               sandbox: %{workdir: "/srv/tet/vps-dev"},
               secret_refs: ["secret://ssh/vps-dev"],
               heartbeat_interval_ms: 5_000
             )

    assert_receive {:fake_remote_request, :bootstrap, request}
    assert request.profile_alias == "vps-dev"
    assert request.worker_ref == "vps-dev"
    assert request.protocol_version == Protocol.supported_protocol_version()
    assert request.secret_refs == ["secret://ssh/vps-dev"]
    assert request.sandbox.workdir == "/srv/tet/vps-dev"
    assert request.heartbeat.interval_ms == 5_000

    assert report.operation == :bootstrap
    assert report.status == :ready
    assert report.worker_ref == "vps-dev"
    assert report.profile_alias == "vps-dev"
    assert report.protocol_version == Protocol.supported_protocol_version()
    assert report.release_version == Protocol.release_version()

    assert report.capabilities.commands == %{enabled: true, entries: ["build", "test"]}
    assert report.capabilities.verifiers == %{enabled: true, entries: ["format", "unit"]}
    assert report.capabilities.artifacts == %{enabled: true}
    assert report.capabilities.cancel == %{enabled: true}
    assert report.capabilities.heartbeat == %{enabled: true}

    assert report.sandbox == %{
             workdir: "/srv/tet/vps-dev",
             profile: "workspace_write",
             network: "disabled",
             policy_summary: %{
               filesystem: "scoped_workdir",
               environment: "scrubbed",
               secrets: "scoped_refs_only"
             }
           }

    assert report.heartbeat == %{
             lease_id: "lease-vps-dev",
             interval_ms: 5_000,
             status: :alive,
             last_seen_monotonic_ms: 42
           }
  end

  test "install and check use the same validated fakeable protocol" do
    profile = %{
      profile_alias: "vps-east",
      worker_ref: "worker-vps-east-1",
      sandbox: %{workdir: "/var/lib/tet/vps-east"}
    }

    assert {:ok, installed} =
             Tet.install_remote_worker(profile,
               transport: FakeTransport,
               transport_opts: [test_pid: self()],
               heartbeat_interval_ms: 7_500
             )

    assert_receive {:fake_remote_request, :install, install_request}
    assert install_request.worker_ref == "worker-vps-east-1"
    assert installed.operation == :install
    assert installed.status == :installed
    assert installed.heartbeat.interval_ms == 7_500

    assert {:ok, checked} =
             Tet.check_remote_worker(profile,
               transport: FakeTransport,
               transport_opts: [test_pid: self()],
               heartbeat_interval_ms: 7_500
             )

    assert_receive {:fake_remote_request, :check, check_request}
    assert check_request.profile_alias == "vps-east"
    assert checked.operation == :check
    assert checked.status == :checked
    assert checked.worker_ref == "worker-vps-east-1"
  end

  test "validation rejects missing workdir, unsupported protocol, and missing heartbeat capability" do
    assert {:error, {:invalid_remote_sandbox_field, :workdir}} =
             Tet.bootstrap_remote_worker("vps-dev", transport: FakeTransport)

    assert {:error, {:unsupported_remote_protocol_version, "tet.remote.bootstrap.v0"}} =
             Tet.bootstrap_remote_worker("vps-dev",
               transport: BadProtocolTransport,
               sandbox: %{workdir: "/srv/tet/vps-dev"}
             )

    assert {:error, {:missing_remote_capability, :heartbeat}} =
             Tet.bootstrap_remote_worker("vps-dev",
               transport: NoHeartbeatTransport,
               sandbox: %{workdir: "/srv/tet/vps-dev"}
             )
  end

  test "report validation binds identity and release version to request" do
    sandbox = %{workdir: "/srv/tet/vps-dev"}

    assert {:error, {:remote_report_mismatch, :worker_ref}} =
             Tet.bootstrap_remote_worker("vps-dev",
               transport: ReportMutationTransport,
               transport_opts: [put_report: [worker_ref: "different-worker"]],
               sandbox: sandbox
             )

    assert {:error, {:remote_report_mismatch, :profile_alias}} =
             Tet.bootstrap_remote_worker("vps-dev",
               transport: ReportMutationTransport,
               transport_opts: [put_report: [profile_alias: "different-profile"]],
               sandbox: sandbox
             )

    assert {:error, {:remote_report_mismatch, :release_version}} =
             Tet.bootstrap_remote_worker("vps-dev",
               transport: ReportMutationTransport,
               transport_opts: [put_report: [release_version: "9.9.9-substituted"]],
               sandbox: sandbox
             )
  end

  test "report validation rejects missing worker_ref" do
    assert {:error, {:invalid_remote_report_field, :worker_ref}} =
             Tet.bootstrap_remote_worker("vps-dev",
               transport: ReportMutationTransport,
               transport_opts: [delete_report: [:worker_ref]],
               sandbox: %{workdir: "/srv/tet/vps-dev"}
             )
  end

  test "report validation rejects missing profile_alias" do
    assert {:error, {:invalid_remote_report_field, :profile_alias}} =
             Tet.bootstrap_remote_worker("vps-dev",
               transport: ReportMutationTransport,
               transport_opts: [delete_report: [:profile_alias]],
               sandbox: %{workdir: "/srv/tet/vps-dev"}
             )
  end

  test "report validation accepts explicit identity aliases" do
    profile = %{
      profile_alias: "vps-east",
      worker_ref: "worker-vps-east-1",
      sandbox: %{workdir: "/var/lib/tet/vps-east"}
    }

    assert {:ok, report} =
             Tet.bootstrap_remote_worker(profile,
               transport: ReportMutationTransport,
               transport_opts: [
                 delete_report: [:worker_ref, :profile_alias],
                 put_report: [worker_id: "worker-vps-east-1", alias: "vps-east"]
               ]
             )

    assert report.worker_ref == "worker-vps-east-1"
    assert report.profile_alias == "vps-east"

    assert {:ok, report} =
             Tet.bootstrap_remote_worker(profile,
               transport: ReportMutationTransport,
               transport_opts: [
                 delete_report: [:worker_ref, :profile_alias],
                 put_report: [{"id", "worker-vps-east-1"}, {"alias", "vps-east"}]
               ]
             )

    assert report.worker_ref == "worker-vps-east-1"
    assert report.profile_alias == "vps-east"
  end

  test "transport options and app env transport stay fakeable and emit safe telemetry" do
    old_transport = Application.get_env(:tet_runtime, :remote_transport)
    Application.put_env(:tet_runtime, :remote_transport, FakeTransport)

    on_exit(fn ->
      if is_nil(old_transport) do
        Application.delete_env(:tet_runtime, :remote_transport)
      else
        Application.put_env(:tet_runtime, :remote_transport, old_transport)
      end
    end)

    telemetry = fn event_name, measurements, metadata ->
      send(self(), {:remote_telemetry, event_name, measurements, metadata})
    end

    assert {:ok, report} =
             Tet.bootstrap_remote_worker("env-vps",
               transport_opts: [test_pid: self()],
               sandbox: %{workdir: "/srv/tet/env-vps"},
               telemetry_emit: telemetry
             )

    assert report.status == :ready
    assert_receive {:fake_remote_request, :bootstrap, request}
    assert request.profile_alias == "env-vps"

    assert_receive {:remote_telemetry, [:tet, :remote, :bootstrap, :start], %{count: 1},
                    start_meta}

    assert start_meta.worker_ref == "env-vps"
    assert start_meta.profile_alias == "env-vps"
    assert start_meta.protocol_version == Protocol.supported_protocol_version()

    assert_receive {:remote_telemetry, [:tet, :remote, :bootstrap, :stop], stop_measurements,
                    stop_meta}

    assert stop_measurements.count == 1
    assert is_integer(stop_measurements.duration_ms)
    assert stop_meta.status == "ready"
    assert stop_meta.release_version == Protocol.release_version()

    assert {:error, {:raw_secret_not_allowed, :password}} =
             Tet.bootstrap_remote_worker("env-vps",
               transport: FakeTransport,
               sandbox: %{workdir: "/srv/tet/env-vps"},
               password: "sk-do-not-log-telemetry",
               telemetry_emit: telemetry
             )

    assert_receive {:remote_telemetry, [:tet, :remote, :bootstrap, :exception],
                    reject_measurements, reject_meta}

    assert reject_measurements.count == 1
    assert is_integer(reject_measurements.duration_ms)
    assert reject_meta.reason == ["raw_secret_not_allowed", "[REDACTED]"]
    refute inspect(reject_meta) =~ "sk-do-not-log-telemetry"
  end

  test "transport edge cases return deterministic safe errors" do
    sandbox = %{workdir: "/srv/tet/vps-dev"}

    telemetry = fn event_name, measurements, metadata ->
      send(self(), {:remote_telemetry, event_name, measurements, metadata})
    end

    assert {:error, %{authorization: "[REDACTED]", message: message}} =
             Tet.bootstrap_remote_worker("vps-dev",
               transport: ErrorTransport,
               sandbox: sandbox,
               telemetry_emit: telemetry
             )

    assert message == "worker failed with [REDACTED]"
    refute inspect(message) =~ "sk-remoteleak456"
    assert_receive {:remote_telemetry, [:tet, :remote, :bootstrap, :start], _, _}
    assert_receive {:remote_telemetry, [:tet, :remote, :bootstrap, :exception], _, error_meta}
    assert error_meta.reason.authorization == "[REDACTED]"
    assert error_meta.reason.message == "worker failed with [REDACTED]"

    assert {:error, {:invalid_remote_transport_response, :bootstrap}} =
             Tet.bootstrap_remote_worker("vps-dev",
               transport: BadShapeTransport,
               sandbox: sandbox
             )

    assert {:error, {:remote_transport_failed, RuntimeError}} =
             Tet.bootstrap_remote_worker("vps-dev", transport: RaisingTransport, sandbox: sandbox)

    assert {:error, {:remote_transport_missing_callback, MissingCheckTransport, :check}} =
             Tet.check_remote_worker("vps-dev",
               transport: MissingCheckTransport,
               sandbox: sandbox
             )

    assert {:error, {:remote_transport_not_loaded, TotallyMissingRemoteTransport}} =
             Tet.bootstrap_remote_worker("vps-dev",
               transport: TotallyMissingRemoteTransport,
               sandbox: sandbox
             )

    assert {:error, {:invalid_remote_transport_opts, :not_a_keyword}} =
             Tet.bootstrap_remote_worker("vps-dev",
               transport: FakeTransport,
               transport_opts: %{nope: true},
               sandbox: sandbox
             )
  end

  test "raw secrets are rejected on input and redacted from worker reports" do
    assert {:error, reason} =
             Tet.bootstrap_remote_worker("vps-dev",
               transport: FakeTransport,
               sandbox: %{workdir: "/srv/tet/vps-dev"},
               password: "please-do-not-log-me"
             )

    assert reason == {:raw_secret_not_allowed, :password}
    refute inspect(reason) =~ "please-do-not-log-me"

    assert {:error, {:raw_secret_not_allowed, :worker_ref}} =
             Tet.bootstrap_remote_worker("Bearer sk-scalarworker123",
               transport: FakeTransport,
               sandbox: %{workdir: "/srv/tet/vps-dev"}
             )

    assert {:error, {:raw_secret_not_allowed, :worker_ref}} =
             Tet.bootstrap_remote_worker("vps-dev",
               transport: FakeTransport,
               worker_ref: "Bearer sk-workeroption123",
               sandbox: %{workdir: "/srv/tet/vps-dev"}
             )

    assert {:error, {:raw_secret_not_allowed, :profile_alias}} =
             Tet.bootstrap_remote_worker("vps-dev",
               transport: FakeTransport,
               profile_alias: "sk-profilealias123",
               sandbox: %{workdir: "/srv/tet/vps-dev"}
             )

    assert {:error, {:raw_secret_not_allowed, :ssh_key}} =
             Tet.bootstrap_remote_worker("vps-dev",
               transport: FakeTransport,
               transport_opts: [
                 ssh_key:
                   "-----BEGIN OPENSSH PRIVATE KEY-----\nabc123\n-----END OPENSSH PRIVATE KEY-----"
               ],
               sandbox: %{workdir: "/srv/tet/vps-dev"}
             )

    assert {:error, {:raw_secret_not_allowed, :authorization}} =
             Tet.bootstrap_remote_worker("vps-dev",
               transport: FakeTransport,
               sandbox: %{workdir: "/srv/tet/vps-dev"},
               authorization: "Bearer sk-do-not-log-me"
             )

    assert {:error, {:raw_secret_not_allowed, :secret_ref}} =
             Tet.bootstrap_remote_worker("vps-dev",
               transport: FakeTransport,
               transport_opts: [secret_ref: "Bearer sk-laundered-via-transport-opts"],
               sandbox: %{workdir: "/srv/tet/vps-dev"}
             )

    assert {:error, {:raw_secret_not_allowed, :auth_secret_ref}} =
             Tet.bootstrap_remote_worker("vps-dev",
               transport: FakeTransport,
               transport_opts: [auth_secret_ref: "AKIAIOSFODNN7EXAMPLE"],
               sandbox: %{workdir: "/srv/tet/vps-dev"}
             )

    for unsafe_ref <- [
          "ssh://user:hunter2@example.test/workdir",
          "http://example.test/?key=sk-do-not-log-me",
          "file:///Users/adam/.ssh/id_rsa"
        ] do
      assert {:error, {:raw_secret_not_allowed, :secret_ref}} =
               Tet.bootstrap_remote_worker("vps-dev",
                 transport: FakeTransport,
                 sandbox: %{workdir: "/srv/tet/vps-dev"},
                 secret_ref: unsafe_ref
               )
    end

    assert {:ok, report} =
             Tet.bootstrap_remote_worker("vps-dev",
               transport: FakeTransport,
               transport_opts: [inject_raw_report_fields?: true],
               sandbox: %{workdir: "/srv/tet/vps-dev"},
               secret_ref: "secret://ssh/vps-dev"
             )

    assert report.metadata.password == "[REDACTED]"
    assert report.metadata.nested.api_key == "[REDACTED]"
    assert report.metadata.nested.secret_ref == "secret://worker/safe"
    refute inspect(report) =~ "super-secret-password"
    refute inspect(report) =~ "raw-api-key"
  end
end
