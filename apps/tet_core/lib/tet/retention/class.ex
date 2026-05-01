defmodule Tet.Retention.Class do
  @moduledoc """
  Retention class definitions for the TET data lifecycle — BD-0037.

  Defines four retention classes that map to the project's data types:

  - `:transient` — Short-lived data safe for aggressive cleanup (temp artifacts,
    ephemeral tool outputs). Default TTL: 24 hours, max count: 1000.

  - `:normal` — Standard operational data with moderate retention (events,
    checkpoints after session end, routine artifacts). Default TTL: 30 days,
    max count: 10_000.

  - `:audit_critical` — Data needed for compliance, audit trails, and
    forensics (approval lifecycle events, workflow steps, error logs).
    Deletion requires explicit acknowledgement and cannot happen silently.
    Default TTL: 1 year, no max count limit.

  - `:permanent` — Data that must never be automatically deleted (approval
    records with terminal status, audit events, resolved error logs with
    repair correlation). No TTL, no max count. Deletion requires operator
    action outside the automatic retention system.

  Each class carries a `ttl_seconds` (or `nil` for permanent), `max_count`
  (or `nil` for unlimited), an `audit_protected?` flag, and a description.
  """

  @classes [:transient, :normal, :audit_critical, :permanent]

  @enforce_keys [:name, :ttl_seconds, :max_count, :audit_protected?, :description]

  defstruct [
    :name,
    :ttl_seconds,
    :max_count,
    :audit_protected?,
    :description,
    metadata: %{}
  ]

  @type name :: :transient | :normal | :audit_critical | :permanent

  @type t :: %__MODULE__{
          name: name(),
          ttl_seconds: pos_integer() | nil,
          max_count: pos_integer() | nil,
          audit_protected?: boolean(),
          description: String.t(),
          metadata: map()
        }

  @doc "Returns all recognised retention class names."
  @spec classes() :: [name()]
  def classes, do: @classes

  @doc """
  Returns the built-in default definition for a retention class.

  ## Examples

      iex> Tet.Retention.Class.default(:transient)
      %Tet.Retention.Class{name: :transient, ttl_seconds: 86_400, max_count: 1_000,
        audit_protected?: false, description: "Short-lived data safe for aggressive cleanup"}

      iex> Tet.Retention.Class.default(:permanent)
      %Tet.Retention.Class{name: :permanent, ttl_seconds: nil, max_count: nil,
        audit_protected?: true, description: "Data that must never be automatically deleted"}
  """
  @spec default(name()) :: t()
  def default(:transient) do
    %__MODULE__{
      name: :transient,
      ttl_seconds: 86_400,
      max_count: 1_000,
      audit_protected?: false,
      description: "Short-lived data safe for aggressive cleanup"
    }
  end

  def default(:normal) do
    %__MODULE__{
      name: :normal,
      ttl_seconds: 2_592_000,
      max_count: 10_000,
      audit_protected?: false,
      description: "Standard operational data with moderate retention"
    }
  end

  def default(:audit_critical) do
    %__MODULE__{
      name: :audit_critical,
      ttl_seconds: 31_536_000,
      max_count: nil,
      audit_protected?: true,
      description: "Data needed for compliance, audit trails, and forensics"
    }
  end

  def default(:permanent) do
    %__MODULE__{
      name: :permanent,
      ttl_seconds: nil,
      max_count: nil,
      audit_protected?: true,
      description: "Data that must never be automatically deleted"
    }
  end

  @doc """
  Builds a class struct from keyword opts, falling back to defaults.

  Accepts any field overrides. Unrecognised names return an error tuple.

  ## Examples

      iex> Tet.Retention.Class.new(:transient, ttl_seconds: 3600)
      {:ok, %Tet.Retention.Class{name: :transient, ttl_seconds: 3600, max_count: 1_000,
        audit_protected?: false}}

      iex> Tet.Retention.Class.new(:nonexistent)
      {:error, :unknown_retention_class}
  """
  @spec new(name(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(name, overrides \\ [])

  def new(name, overrides) when name in @classes and is_list(overrides) do
    defaults = default(name)
    merged = apply_overrides(defaults, overrides)
    {:ok, merged}
  end

  def new(name, _overrides) when is_atom(name) do
    {:error, :unknown_retention_class}
  end

  @doc """
  Returns true if the class is audit-protected (requires explicit acknowledgement
  before deletion).
  """
  @spec audit_protected?(t()) :: boolean()
  def audit_protected?(%__MODULE__{audit_protected?: value}), do: value
  def audit_protected?(_other), do: false

  @doc """
  Returns true if the class has a finite TTL (is not permanent).
  """
  @spec finite_ttl?(t()) :: boolean()
  def finite_ttl?(%__MODULE__{ttl_seconds: nil}), do: false
  def finite_ttl?(%__MODULE__{}), do: true
  def finite_ttl?(_other), do: false

  @doc """
  Returns true if the class has a max count limit.
  """
  @spec bounded_count?(t()) :: boolean()
  def bounded_count?(%__MODULE__{max_count: nil}), do: false
  def bounded_count?(%__MODULE__{}), do: true
  def bounded_count?(_other), do: false

  # -- Private helpers --

  defp apply_overrides(class, []) do
    class
  end

  defp apply_overrides(class, [{:ttl_seconds, nil} | rest]) do
    apply_overrides(%{class | ttl_seconds: nil}, rest)
  end

  defp apply_overrides(class, [{:ttl_seconds, value} | rest])
       when is_integer(value) and value >= 0 do
    apply_overrides(%{class | ttl_seconds: value}, rest)
  end

  defp apply_overrides(class, [{:max_count, nil} | rest]) do
    apply_overrides(%{class | max_count: nil}, rest)
  end

  defp apply_overrides(class, [{:max_count, value} | rest])
       when is_integer(value) and value >= 0 do
    apply_overrides(%{class | max_count: value}, rest)
  end

  defp apply_overrides(class, [{:audit_protected?, value} | rest]) when is_boolean(value) do
    apply_overrides(%{class | audit_protected?: value}, rest)
  end

  defp apply_overrides(class, [{:description, value} | rest]) when is_binary(value) do
    apply_overrides(%{class | description: value}, rest)
  end

  defp apply_overrides(class, [{:metadata, value} | rest]) when is_map(value) do
    apply_overrides(%{class | metadata: value}, rest)
  end

  defp apply_overrides(class, [_skip | rest]) do
    apply_overrides(class, rest)
  end
end
