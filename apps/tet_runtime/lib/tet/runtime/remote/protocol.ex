defmodule Tet.Runtime.Remote.Protocol do
  @moduledoc """
  Pure validation and normalization for the remote-worker bootstrap protocol.

  The protocol is intentionally boring data: version, capabilities, sandbox, and
  heartbeat. Request-side capabilities are negotiation/reporting hints only; they
  do **not** authorize execution, skip approvals, or smuggle secrets. Boring is
  good. Boring does not wake you up at 03:00.
  """

  alias Tet.Runtime.Remote.{Capabilities, Report, Request, Secrets}

  @protocol_version "tet.remote.bootstrap.v1"
  @operations [:bootstrap, :install, :check]
  @report_statuses [:ready, :installed, :checked, :degraded, :error]
  @heartbeat_statuses [:starting, :alive, :stale, :expired, :unknown]

  @doc "Returns the only bootstrap protocol version supported by this release."
  def supported_protocol_version, do: @protocol_version

  @doc "Returns the local runtime release version included in bootstrap requests."
  def release_version do
    case Application.spec(:tet_runtime, :vsn) do
      nil -> "0.1.0"
      vsn when is_list(vsn) -> List.to_string(vsn)
      vsn -> to_string(vsn)
    end
  end

  @doc "Builds a validated remote bootstrap/install/check request."
  @spec build_request(atom() | binary(), term(), keyword()) ::
          {:ok, Request.t()} | {:error, term()}
  def build_request(operation, worker_ref, opts \\ []) when is_list(opts) do
    attrs = if is_map(worker_ref), do: worker_ref, else: %{}

    with :ok <- assert_no_raw_secrets(opts),
         :ok <- assert_no_raw_secrets(attrs),
         :ok <- assert_no_scalar_worker_ref_secret(worker_ref),
         {:ok, operation} <- normalize_operation(operation),
         {:ok, profile_alias} <- normalize_profile_alias(worker_ref, opts),
         {:ok, worker_ref} <- normalize_worker_ref(worker_ref, profile_alias, opts),
         :ok <- assert_no_identity_raw_secret(profile_alias, :profile_alias),
         :ok <- assert_no_identity_raw_secret(worker_ref, :worker_ref),
         {:ok, protocol_version} <- request_protocol_version(opts),
         {:ok, release_version} <-
           normalize_non_empty(
             fetch_option(opts, :release_version, release_version()),
             :release_version
           ),
         {:ok, capabilities} <-
           Capabilities.normalize(fetch_option(opts, :capabilities, Capabilities.kinds())),
         {:ok, sandbox} <- normalize_request_sandbox(attrs, opts),
         {:ok, heartbeat} <- normalize_request_heartbeat(opts),
         {:ok, secret_refs} <- Secrets.normalize_refs(fetch_option(opts, :secret_refs, []), opts),
         {:ok, metadata} <- normalize_metadata(fetch_option(opts, :metadata, %{})) do
      {:ok,
       %Request{
         operation: operation,
         worker_ref: worker_ref,
         profile_alias: profile_alias,
         protocol_version: protocol_version,
         release_version: release_version,
         capabilities: capabilities,
         sandbox: sandbox,
         heartbeat: heartbeat,
         secret_refs: secret_refs,
         metadata: metadata
       }}
    end
  end

  @doc "Validates and redacts a transport response into a worker report."
  @spec validate_report(atom(), Request.t(), map()) :: {:ok, Report.t()} | {:error, term()}
  def validate_report(operation, %Request{} = request, raw_report) when is_map(raw_report) do
    redacted_report = redact_raw_secrets(raw_report)

    with {:ok, operation} <- normalize_operation(operation),
         {:ok, status} <-
           normalize_report_status(
             fetch_value(redacted_report, :status, default_status(operation))
           ),
         {:ok, worker_ref} <-
           normalize_report_identity(
             fetch_value(redacted_report, :worker_ref, nil, [:worker_id, :id]),
             :worker_ref
           ),
         :ok <- report_matches_request(worker_ref, request.worker_ref, :worker_ref),
         {:ok, profile_alias} <-
           normalize_report_identity(
             fetch_value(redacted_report, :profile_alias, nil, [:alias]),
             :profile_alias
           ),
         :ok <- report_matches_request(profile_alias, request.profile_alias, :profile_alias),
         {:ok, protocol_version} <- report_protocol_version(redacted_report),
         {:ok, release_version} <-
           normalize_non_empty(
             fetch_value(redacted_report, :release_version, nil, [:version]),
             :release_version
           ),
         :ok <- report_matches_request(release_version, request.release_version, :release_version),
         {:ok, capabilities} <- report_capabilities(redacted_report),
         :ok <- Capabilities.require_enabled(capabilities, :heartbeat),
         {:ok, sandbox} <- report_sandbox(redacted_report),
         {:ok, heartbeat} <- report_heartbeat(redacted_report),
         {:ok, metadata} <- normalize_metadata(fetch_value(redacted_report, :metadata, %{})) do
      {:ok,
       %Report{
         operation: operation,
         status: status,
         worker_ref: worker_ref,
         profile_alias: profile_alias,
         protocol_version: protocol_version,
         release_version: release_version,
         capabilities: capabilities,
         sandbox: sandbox,
         heartbeat: heartbeat,
         metadata: metadata
       }}
    end
  end

  def validate_report(_operation, %Request{}, _raw_report) do
    {:error, {:invalid_remote_report, :not_a_map}}
  end

  @doc "Recursively redacts raw secret-looking fields while preserving scoped refs."
  def redact_raw_secrets(value), do: Secrets.redact(value)

  @doc "Rejects maps/keyword data that attempt to carry raw secret fields."
  def assert_no_raw_secrets(value), do: Secrets.assert_no_raw(value)

  @doc "Rejects transport options that attempt to carry raw SSH/key material."
  def assert_no_transport_raw_secrets(value), do: Secrets.assert_no_raw_transport(value)

  defp normalize_request_sandbox(attrs, opts) do
    sandbox = fetch_option(opts, :sandbox, fetch_value(attrs, :sandbox, %{}))

    if is_map(sandbox) do
      workdir =
        first_present([
          fetch_option(opts, :workdir),
          fetch_value(sandbox, :workdir),
          fetch_value(attrs, :workdir)
        ])

      with {:ok, workdir} <- normalize_non_empty(workdir, :workdir),
           {:ok, profile} <-
             normalize_sandbox_text(
               first_present([
                 fetch_value(sandbox, :profile),
                 fetch_value(sandbox, :sandbox_profile),
                 fetch_value(attrs, :sandbox_profile),
                 "isolated"
               ]),
               :profile
             ),
           {:ok, network} <-
             normalize_sandbox_text(
               first_present([
                 fetch_value(sandbox, :network),
                 fetch_value(attrs, :network),
                 "disabled"
               ]),
               :network
             ),
           {:ok, policy_summary} <-
             normalize_policy_summary(
               first_present([
                 fetch_value(sandbox, :policy_summary),
                 fetch_value(sandbox, :policy),
                 fetch_value(attrs, :policy_summary),
                 default_policy_summary()
               ])
             ) do
        {:ok,
         %{
           workdir: workdir,
           profile: profile,
           network: network,
           policy_summary: policy_summary
         }}
      end
    else
      {:error, {:invalid_remote_sandbox_field, :sandbox}}
    end
  end

  defp report_sandbox(report) do
    case fetch_value(report, :sandbox) do
      sandbox when is_map(sandbox) ->
        with {:ok, workdir} <- normalize_non_empty(fetch_value(sandbox, :workdir), :workdir),
             {:ok, profile} <-
               normalize_sandbox_text(
                 fetch_value(sandbox, :profile, "isolated", [:sandbox_profile]),
                 :profile
               ),
             {:ok, network} <-
               normalize_sandbox_text(fetch_value(sandbox, :network, "disabled"), :network),
             {:ok, policy_summary} <-
               normalize_policy_summary(
                 fetch_value(sandbox, :policy_summary, default_policy_summary(), [:policy])
               ) do
          {:ok,
           %{
             workdir: workdir,
             profile: profile,
             network: network,
             policy_summary: policy_summary
           }}
        end

      _other ->
        {:error, {:invalid_remote_report_field, :sandbox}}
    end
  end

  defp normalize_request_heartbeat(opts) do
    heartbeat = fetch_option(opts, :heartbeat, %{})

    if is_map(heartbeat) do
      attrs = %{
        interval_ms:
          first_present([
            fetch_option(opts, :heartbeat_interval_ms),
            fetch_value(heartbeat, :interval_ms),
            15_000
          ]),
        status: :starting,
        last_seen_monotonic_ms: 0
      }

      normalize_heartbeat(attrs, lease_required?: false, last_seen_required?: false)
    else
      {:error, {:invalid_remote_heartbeat_field, :heartbeat}}
    end
  end

  defp report_heartbeat(report) do
    case fetch_value(report, :heartbeat) do
      heartbeat when is_map(heartbeat) ->
        normalize_heartbeat(heartbeat, lease_required?: true, last_seen_required?: true)

      _other ->
        {:error, {:invalid_remote_report_field, :heartbeat}}
    end
  end

  defp normalize_heartbeat(attrs, opts) do
    with {:ok, interval_ms} <-
           normalize_positive_integer(
             fetch_value(attrs, :interval_ms, nil, [:heartbeat_interval_ms]),
             :interval_ms
           ),
         {:ok, status} <- normalize_heartbeat_status(fetch_value(attrs, :status, :unknown)),
         {:ok, lease_id} <-
           normalize_optional_lease_id(
             fetch_value(attrs, :lease_id),
             Keyword.fetch!(opts, :lease_required?)
           ),
         {:ok, last_seen} <-
           normalize_last_seen(
             fetch_value(attrs, :last_seen_monotonic_ms, nil, [:last_seen_ms, :last_seen]),
             Keyword.fetch!(opts, :last_seen_required?)
           ) do
      heartbeat = %{
        interval_ms: interval_ms,
        status: status,
        last_seen_monotonic_ms: last_seen
      }

      {:ok, put_optional(heartbeat, :lease_id, lease_id, nil)}
    end
  end

  defp report_capabilities(report) do
    case fetch_value(report, :capabilities) do
      nil -> {:error, {:invalid_remote_report_field, :capabilities}}
      capabilities -> Capabilities.normalize(capabilities)
    end
  end

  defp normalize_operation(operation) when operation in @operations, do: {:ok, operation}

  defp normalize_operation(operation) when is_binary(operation) do
    Enum.find(@operations, &(Atom.to_string(&1) == String.trim(operation)))
    |> case do
      nil -> {:error, {:invalid_remote_operation, operation}}
      operation -> {:ok, operation}
    end
  end

  defp normalize_operation(operation), do: {:error, {:invalid_remote_operation, operation}}

  defp assert_no_scalar_worker_ref_secret(worker_ref) when is_map(worker_ref), do: :ok

  defp assert_no_scalar_worker_ref_secret(worker_ref) do
    assert_no_identity_raw_secret(worker_ref, :worker_ref)
  end

  defp assert_no_identity_raw_secret(value, field) do
    case assert_no_raw_secrets(value) do
      :ok -> :ok
      {:error, {:raw_secret_not_allowed, _path}} -> {:error, {:raw_secret_not_allowed, field}}
    end
  end

  defp report_matches_request(value, value, _field), do: :ok

  defp report_matches_request(_report_value, _request_value, field),
    do: {:error, {:remote_report_mismatch, field}}

  defp normalize_report_identity(value, field) do
    case normalize_non_empty(value, field) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, _reason} -> {:error, {:invalid_remote_report_field, field}}
    end
  end

  defp normalize_profile_alias(worker_ref, opts) do
    value =
      case worker_ref do
        ref when is_binary(ref) or is_atom(ref) ->
          ref

        attrs when is_map(attrs) ->
          fetch_value(attrs, :profile_alias, nil, [:alias, :profile, :id])

        _other ->
          nil
      end

    normalize_non_empty(fetch_option(opts, :profile_alias, value), :profile_alias)
  end

  defp normalize_worker_ref(worker_ref, profile_alias, opts) do
    value =
      case worker_ref do
        ref when is_binary(ref) or is_atom(ref) ->
          ref

        attrs when is_map(attrs) ->
          fetch_value(attrs, :worker_ref, profile_alias, [:worker_id, :id])

        _other ->
          nil
      end

    normalize_non_empty(fetch_option(opts, :worker_ref, value), :worker_ref)
  end

  defp request_protocol_version(opts) do
    case fetch_option(opts, :protocol_version, @protocol_version) do
      @protocol_version -> {:ok, @protocol_version}
      version -> {:error, {:unsupported_remote_protocol_version, version}}
    end
  end

  defp report_protocol_version(report) do
    case fetch_value(report, :protocol_version) do
      @protocol_version -> {:ok, @protocol_version}
      nil -> {:error, {:invalid_remote_report_field, :protocol_version}}
      version -> {:error, {:unsupported_remote_protocol_version, version}}
    end
  end

  defp normalize_report_status(status) when status in @report_statuses, do: {:ok, status}

  defp normalize_report_status(status) when is_binary(status) do
    Enum.find(@report_statuses, &(Atom.to_string(&1) == String.trim(status)))
    |> case do
      nil -> {:error, {:invalid_remote_report_status, status}}
      status -> {:ok, status}
    end
  end

  defp normalize_report_status(status), do: {:error, {:invalid_remote_report_status, status}}

  defp normalize_heartbeat_status(status) when status in @heartbeat_statuses, do: {:ok, status}

  defp normalize_heartbeat_status(status) when is_binary(status) do
    Enum.find(@heartbeat_statuses, &(Atom.to_string(&1) == String.trim(status)))
    |> case do
      nil -> {:error, {:invalid_remote_heartbeat_status, status}}
      status -> {:ok, status}
    end
  end

  defp normalize_heartbeat_status(status),
    do: {:error, {:invalid_remote_heartbeat_status, status}}

  defp normalize_optional_lease_id(nil, false), do: {:ok, nil}

  defp normalize_optional_lease_id(nil, true),
    do: {:error, {:invalid_remote_heartbeat_field, :lease_id}}

  defp normalize_optional_lease_id(value, _required), do: normalize_non_empty(value, :lease_id)

  defp normalize_last_seen(nil, false), do: {:ok, 0}

  defp normalize_last_seen(nil, true),
    do: {:error, {:invalid_remote_heartbeat_field, :last_seen_monotonic_ms}}

  defp normalize_last_seen(value, _required),
    do: normalize_non_negative_integer(value, :last_seen_monotonic_ms)

  defp normalize_metadata(metadata) when is_map(metadata), do: {:ok, redact_raw_secrets(metadata)}
  defp normalize_metadata(_metadata), do: {:error, {:invalid_remote_metadata, :not_a_map}}

  defp normalize_policy_summary(policy_summary) when is_map(policy_summary) do
    {:ok, redact_raw_secrets(policy_summary)}
  end

  defp normalize_policy_summary(_policy_summary),
    do: {:error, {:invalid_remote_sandbox_field, :policy_summary}}

  defp normalize_sandbox_text(value, field), do: normalize_non_empty(value, field)

  defp normalize_positive_integer(value, _field) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp normalize_positive_integer(_value, field),
    do: {:error, {:invalid_remote_heartbeat_field, field}}

  defp normalize_non_negative_integer(value, _field) when is_integer(value) and value >= 0,
    do: {:ok, value}

  defp normalize_non_negative_integer(_value, field),
    do: {:error, {:invalid_remote_heartbeat_field, field}}

  defp normalize_non_empty(value, field)
       when is_atom(value) and value not in [nil, true, false] do
    value |> Atom.to_string() |> normalize_non_empty(field)
  end

  defp normalize_non_empty(value, field) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, invalid_field_error(field)}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_non_empty(_value, field), do: {:error, invalid_field_error(field)}

  defp invalid_field_error(field) when field in [:workdir, :profile, :network] do
    {:invalid_remote_sandbox_field, field}
  end

  defp invalid_field_error(field)
       when field in [:worker_ref, :profile_alias, :release_version, :lease_id] do
    {:invalid_remote_request_field, field}
  end

  defp invalid_field_error(field), do: {:invalid_remote_field, field}

  defp fetch_value(attrs, key, default \\ nil, aliases \\ []) when is_map(attrs) do
    keys = [key, Atom.to_string(key) | alias_keys(aliases)]

    Enum.reduce_while(keys, default, fn candidate, _acc ->
      if Map.has_key?(attrs, candidate) do
        {:halt, Map.get(attrs, candidate)}
      else
        {:cont, default}
      end
    end)
  end

  defp fetch_option(opts, key, default \\ nil), do: Keyword.get(opts, key, default)

  defp alias_keys(aliases) do
    Enum.flat_map(aliases, fn
      alias_key when is_atom(alias_key) -> [alias_key, Atom.to_string(alias_key)]
      alias_key -> [alias_key]
    end)
  end

  defp first_present(values), do: Enum.find(values, &present?/1)

  defp present?(nil), do: false
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: true

  defp default_status(:bootstrap), do: :ready
  defp default_status(:install), do: :installed
  defp default_status(:check), do: :checked

  defp default_policy_summary do
    %{
      environment: "scrubbed",
      filesystem: "scoped_workdir",
      secrets: "scoped_refs_only"
    }
  end

  defp put_optional(map, _key, value, value), do: map
  defp put_optional(map, key, value, _empty), do: Map.put(map, key, value)
end
