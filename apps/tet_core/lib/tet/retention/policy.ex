defmodule Tet.Retention.Policy do
  @moduledoc """
  Configurable retention policy for TET data types — BD-0037.

  Maps each data type to a retention class and provides configurable overrides
  per class. Policies are loaded from application config or constructed
  programmatically via `new/1`.

  ## Data type → class mapping

  The default mapping assigns each data type a retention class:

      Event.Log        → :audit_critical
      Event.Approval   → :permanent
      Event.Workflow   → :audit_critical
      Artifact.General → :normal
      Artifact.Sensitive→ :audit_critical
      Checkpoint       → :transient
      ErrorLog         → :audit_critical
      Repair           → :audit_critical
      Workflow         → :audit_critical
      WorkflowStep     → :audit_critical

  Each class can have its TTL and max_count overridden through configuration
  or programmatically. Audit-critical and permanent records are **never**
  silently deletable — they require explicit operator acknowledgement.

  ## Configuration

  In config/config.exs:

      config :tet_core, Tet.Retention.Policy,
        classes: [
          transient: [ttl_seconds: 3600, max_count: 500],
          audit_critical: [ttl_seconds: 63_072_000]  # 2 years
        ],
        overrides: [
          checkpoint: :normal  # override checkpoint class to :normal
        ]
  """

  alias Tet.Retention.Class

  @typedoc """
  Data types that can have retention policies applied.

  These correspond to the entity families in the store. Adding a new data
  type requires a mapping entry in the class_map.
  """
  @type data_type ::
          :event_log
          | :approval
          | :artifact
          | :checkpoint
          | :error_log
          | :repair
          | :workflow
          | :workflow_step

  @typedoc """
  An acknowledgment token returned when an audit-protected deletion is
  explicitly acknowledged. Must be presented to `Tet.Retention.Enforcer`
  to complete the deletion.
  """
  @type ack_token :: binary()

  @enforce_keys [:classes]
  defstruct [
    :classes,
    data_type_map: %{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          classes: %{required(Class.name()) => Class.t()},
          data_type_map: %{required(data_type()) => Class.name()},
          metadata: map()
        }

  @doc """
  Returns the default data type → class mapping.

  This is the canonical mapping per §04 retention design. Audit-critical
  and permanent classes are never pruned without explicit acknowledgement.
  """
  @spec default_data_type_map() :: %{required(data_type()) => Class.name()}
  def default_data_type_map do
    %{
      event_log: :audit_critical,
      approval: :permanent,
      artifact: :normal,
      checkpoint: :transient,
      error_log: :audit_critical,
      repair: :audit_critical,
      workflow: :audit_critical,
      workflow_step: :audit_critical
    }
  end

  @doc """
  Builds a Policy from keyword opts.

  Accepts:
  - `:classes` — keyword list of `{class_name, overrides}` pairs
  - `:overrides` — keyword list of `{data_type, class_name}` to remap data types
  - `:metadata` — optional metadata map

  ## Examples

      iex> {:ok, policy} = Tet.Retention.Policy.new(classes: [transient: [ttl_seconds: 3600]])
      iex> policy.classes.transient.ttl_seconds
      3600

      iex> {:ok, policy} = Tet.Retention.Policy.new(overrides: [checkpoint: :normal])
      iex> policy.data_type_map.checkpoint
      :normal
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts \\ [])

  def new(opts) when is_list(opts) do
    class_overrides = Keyword.get(opts, :classes, [])
    data_type_overrides = Keyword.get(opts, :overrides, [])
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, classes} <- build_classes(class_overrides),
         {:ok, data_type_map} <- build_data_type_map(data_type_overrides) do
      {:ok,
       %__MODULE__{
         classes: classes,
         data_type_map: data_type_map,
         metadata: metadata
       }}
    end
  end

  def new(_opts), do: {:error, :invalid_policy_opts}

  @doc """
  Loads the policy from application config with defaults applied.

  Configuration keys under `[:tet_core, Tet.Retention.Policy]`:
  - `:classes` — overrides for class definitions
  - `:overrides` — data type → class remapping
  """
  @spec load() :: t()
  def load do
    config = Application.get_env(:tet_core, __MODULE__, [])

    case new(config) do
      {:ok, policy} -> policy
      {:error, _reason} -> new([]) |> elem(1)
    end
  end

  @doc """
  Returns the retention class for a given data type.

  Raises `ArgumentError` for unknown data types.
  """
  @spec class_for(t(), data_type()) :: Class.t()
  def class_for(%__MODULE__{classes: classes, data_type_map: map}, data_type)
      when is_atom(data_type) do
    case Map.fetch(map, data_type) do
      {:ok, class_name} ->
        Map.fetch!(classes, class_name)

      :error ->
        raise ArgumentError, "unknown data type for retention policy: #{inspect(data_type)}"
    end
  end

  @doc """
  Returns whether a data type is audit-protected in this policy.

  Audit-protected data types require explicit acknowledgement before any
  deletion can proceed. This is a hard gate — see `Tet.Retention.Enforcer`.
  """
  @spec audit_protected?(t(), data_type()) :: boolean()
  def audit_protected?(%__MODULE__{} = policy, data_type) do
    policy
    |> class_for(data_type)
    |> Class.audit_protected?()
  end

  @doc """
  Returns whether records of this data type can ever be eligible for automatic
  deletion (i.e., they have a finite TTL or bounded count).
  """
  @spec deletable?(t(), data_type()) :: boolean()
  def deletable?(%__MODULE__{} = policy, data_type) do
    class = class_for(policy, data_type)
    Class.finite_ttl?(class) or Class.bounded_count?(class)
  end

  @doc """
  Returns the TTL in seconds for a data type, or `nil` if permanent.
  """
  @spec ttl_seconds(t(), data_type()) :: pos_integer() | nil
  def ttl_seconds(%__MODULE__{} = policy, data_type) do
    policy |> class_for(data_type) |> Map.fetch!(:ttl_seconds)
  end

  @doc """
  Returns the max count for a data type, or `nil` if unlimited.
  """
  @spec max_count(t(), data_type()) :: pos_integer() | nil
  def max_count(%__MODULE__{} = policy, data_type) do
    policy |> class_for(data_type) |> Map.fetch!(:max_count)
  end

  @doc """
  Returns the audit acknowledgement token for deletion of an audit-protected
  record.

  The token encodes the class name, record ID, actor identity, a random nonce,
  and a timestamp signed with HMAC-SHA256 using the configured secret. This
  makes tokens non-forgeable and non-replayable across restarts.

  The `:actor` option identifies who or what is acknowledging the deletion.
  Must be presented to `Tet.Retention.Enforcer.acknowledged_delete/4` to
  complete the operation.
  """
  @spec generate_ack_token(t(), data_type(), binary(), keyword()) :: ack_token()
  def generate_ack_token(%__MODULE__{} = policy, data_type, record_id, opts \\ [])
      when is_atom(data_type) and is_binary(record_id) and is_list(opts) do
    class = class_for(policy, data_type)
    actor = Keyword.get(opts, :actor, "system")
    nonce = Keyword.get(opts, :nonce, generate_nonce())
    timestamp = Keyword.get(opts, :timestamp, DateTime.utc_now() |> DateTime.to_iso8601())

    secret = ack_secret()
    payload = "#{nonce}|#{timestamp}|#{actor}|#{class.name}|#{record_id}"
    hmac = :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower)

    # Encode nonce, timestamp, actor, and hmac into the token for self-validation
    raw = "#{nonce}|#{timestamp}|#{actor}|#{hmac}"
    Base.url_encode64(raw)
  end

  @doc """
  Returns the metadata for the policy.
  """
  @spec metadata(t()) :: map()
  def metadata(%__MODULE__{metadata: metadata}), do: metadata

  # -- Private helpers --

  @audit_critical_data_types [
    :event_log,
    :approval,
    :error_log,
    :repair,
    :workflow,
    :workflow_step
  ]

  @doc false
  def audit_critical_data_types, do: @audit_critical_data_types

  defp build_classes([]) do
    {:ok,
     %{
       transient: Class.default(:transient),
       normal: Class.default(:normal),
       audit_critical: Class.default(:audit_critical),
       permanent: Class.default(:permanent)
     }}
  end

  defp build_classes(overrides) when is_list(overrides) do
    result =
      Enum.reduce_while(overrides, {:ok, %{}}, fn {name, opts}, {:ok, acc} ->
        case Class.new(name, opts) do
          {:ok, class} -> {:cont, {:ok, Map.put(acc, name, class)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, classes} ->
        all_classes =
          Class.classes()
          |> Enum.reduce(classes, fn name, acc ->
            Map.put_new(acc, name, Class.default(name))
          end)

        # Hard safety invariants: permanent and audit_critical must remain protected
        with {:ok, _} <- assert_class_protected(all_classes, :permanent),
             {:ok, _} <- assert_class_protected(all_classes, :audit_critical) do
          {:ok, all_classes}
        end

      {:error, _} = error ->
        error
    end
  end

  defp build_data_type_map([]) do
    {:ok, default_data_type_map()}
  end

  defp build_data_type_map(overrides) when is_list(overrides) do
    base = default_data_type_map()

    result =
      Enum.reduce_while(overrides, {:ok, base}, fn {data_type, class_name}, {:ok, acc} ->
        cond do
          class_name not in Class.classes() ->
            {:halt, {:error, {:unknown_retention_class, class_name}}}

          data_type in @audit_critical_data_types and
              not audit_class_protected?(class_name, acc) ->
            {:halt, {:error, {:cannot_unprotect_audit_critical_type, data_type}}}

          true ->
            {:cont, {:ok, Map.put(acc, data_type, class_name)}}
        end
      end)

    result
  end

  defp assert_class_protected(classes, class_name) do
    case Map.fetch(classes, class_name) do
      {:ok, %Class{audit_protected?: true}} ->
        {:ok, classes}

      {:ok, %Class{audit_protected?: false}} ->
        {:error, {:class_must_be_audit_protected, class_name}}

      :error ->
        {:error, {:class_not_found, class_name}}
    end
  end

  defp audit_class_protected?(class_name, _data_type_map) do
    # Check if the target class is itself audit-protected by looking up
    # its definition. We need the classes map for that, but at this point
    # we only have the data_type_map. We check against the built-in defaults.
    default_class = Class.default(class_name)
    Class.audit_protected?(default_class)
  end

  defp generate_nonce do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp ack_secret do
    # Application config is the highest priority override (used in tests)
    config = Application.get_env(:tet_core, __MODULE__, [])

    case Keyword.get(config, :ack_secret) do
      nil ->
        # Fall back to cached persistent_term or generate new default
        case :persistent_term.get({__MODULE__, :ack_secret}, :not_set) do
          :not_set ->
            secret = default_ack_secret()
            :persistent_term.put({__MODULE__, :ack_secret}, secret)
            secret

          secret ->
            secret
        end

      configured ->
        configured
    end
  end

  defp default_ack_secret do
    # Generate a per-boot secret so tokens are invalidated on restart
    # unless a persistent secret is configured.
    :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
  end
end
