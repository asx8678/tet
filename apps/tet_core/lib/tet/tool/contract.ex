defmodule Tet.Tool.Contract do
  @moduledoc """
  Typed manifest for a native tool contract.

  A contract describes the provider/runtime boundary. It does not execute
  anything, touch the filesystem, shell out, persist events, or ask a terminal
  question by itself. Future runtime layers must consume this manifest before
  dispatching read-only tools, then apply policy, redaction, correlation, and
  event capture as required by the plan.
  """

  @required_fields [
    :name,
    :namespace,
    :version,
    :title,
    :description,
    :read_only,
    :interactive,
    :mutation,
    :approval,
    :modes,
    :task_categories,
    :input_schema,
    :output_schema,
    :error_schema,
    :limits,
    :redaction,
    :correlation,
    :execution,
    :source
  ]
  @optional_fields [:aliases]
  @known_fields @required_fields ++ @optional_fields
  @schema_required_fields [:type, :properties, :required, :additional_properties]
  @limit_fields [:paths, :results, :bytes, :timeout_ms]
  @redaction_fields [:class, :apply_before, :rules]
  @correlation_fields [:required, :optional, :schema, :propagation]
  @approval_fields [:required, :reason]
  @execution_fields [
    :status,
    :executor,
    :effects,
    :mutates_workspace,
    :mutates_store,
    :executes_code
  ]
  @field_names Map.new(@known_fields, fn field -> {Atom.to_string(field), field} end)

  @enforce_keys @required_fields
  defstruct @required_fields ++ [aliases: []]

  @type schema :: map()
  @type limits :: %{
          required(:paths) => map(),
          required(:results) => map(),
          required(:bytes) => map(),
          required(:timeout_ms) => pos_integer()
        }
  @type redaction :: %{
          required(:class) => atom(),
          required(:apply_before) => [atom()],
          required(:rules) => [map()],
          optional(atom()) => term()
        }
  @type correlation :: %{
          required(:required) => [binary()],
          required(:optional) => [binary()],
          required(:schema) => schema(),
          required(:propagation) => [atom()],
          optional(atom()) => term()
        }
  @type approval :: %{
          required(:required) => false,
          required(:reason) => binary(),
          optional(atom()) => term()
        }
  @type execution :: %{
          required(:status) => atom(),
          required(:executor) => atom(),
          required(:effects) => [atom()],
          required(:mutates_workspace) => false,
          required(:mutates_store) => false,
          required(:executes_code) => false,
          optional(atom()) => term()
        }
  @type t :: %__MODULE__{
          name: binary(),
          namespace: binary(),
          version: binary(),
          title: binary(),
          description: binary(),
          read_only: true,
          interactive: boolean(),
          mutation: :none,
          approval: approval(),
          modes: [atom()],
          task_categories: [atom()],
          input_schema: schema(),
          output_schema: schema(),
          error_schema: schema(),
          limits: limits(),
          redaction: redaction(),
          correlation: correlation(),
          execution: execution(),
          source: map(),
          aliases: [binary()]
        }

  @doc "Returns required top-level contract fields."
  @spec required_fields() :: [atom()]
  def required_fields, do: @required_fields

  @doc "Returns optional top-level contract fields."
  @spec optional_fields() :: [atom()]
  def optional_fields, do: @optional_fields

  @doc "Returns all known top-level contract fields."
  @spec known_fields() :: [atom()]
  def known_fields, do: @known_fields

  @doc "Returns required JSON-schema-like keys for input, output, and error schemas."
  @spec schema_required_fields() :: [atom()]
  def schema_required_fields, do: @schema_required_fields

  @doc "Returns required limit categories every contract must declare."
  @spec limit_fields() :: [atom()]
  def limit_fields, do: @limit_fields

  @doc "Returns required redaction metadata fields every contract must declare."
  @spec redaction_fields() :: [atom()]
  def redaction_fields, do: @redaction_fields

  @doc "Returns required correlation metadata fields every contract must declare."
  @spec correlation_fields() :: [atom()]
  def correlation_fields, do: @correlation_fields

  @doc "Builds a validated contract from atom or string keyed attributes."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    normalized =
      attrs
      |> normalize_keys()
      |> normalize_list_values()

    with :ok <- reject_unknown_fields(normalized),
         :ok <- require_fields(normalized),
         contract <- struct(__MODULE__, Map.take(normalized, @known_fields)),
         :ok <- validate(contract) do
      {:ok, contract}
    end
  end

  @doc "Builds a contract or raises `ArgumentError` with a stable reason."
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    case new(attrs) do
      {:ok, contract} ->
        contract

      {:error, reason} ->
        raise ArgumentError, "invalid tool contract: #{inspect(reason)}"
    end
  end

  @doc "Validates a contract struct."
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = contract) do
    with :ok <- validate_binary(:name, contract.name),
         :ok <- validate_binary(:namespace, contract.namespace),
         :ok <- validate_binary(:version, contract.version),
         :ok <- validate_binary(:title, contract.title),
         :ok <- validate_binary(:description, contract.description),
         :ok <- validate_read_only(contract),
         :ok <- validate_boolean(:interactive, contract.interactive),
         :ok <- validate_atom_list(:modes, contract.modes),
         :ok <- validate_atom_list(:task_categories, contract.task_categories),
         :ok <- validate_aliases(contract.aliases),
         :ok <- validate_approval(contract.approval),
         :ok <- validate_schema(:input_schema, contract.input_schema),
         :ok <- validate_schema(:output_schema, contract.output_schema),
         :ok <- validate_schema(:error_schema, contract.error_schema),
         :ok <- validate_limits(contract.limits),
         :ok <- validate_redaction(contract.redaction),
         :ok <- validate_correlation(contract.correlation),
         :ok <- validate_execution(contract.execution),
         :ok <- validate_map(:source, contract.source) do
      :ok
    end
  end

  @doc "Converts the contract to a JSON-friendly map with string keys and values."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = contract) do
    contract
    |> Map.from_struct()
    |> json_safe()
  end

  defp normalize_keys(attrs) do
    Map.new(attrs, fn {key, value} -> {normalize_key(key), value} end)
  end

  @atom_list_fields [:modes, :task_categories]

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: Map.get(@field_names, key, key)
  defp normalize_key(key), do: key

  # Normalize string elements in atom-valued list fields so the gate always
  # sees a Contract.t() with atom modes and task_categories.
  defp normalize_list_values(attrs) do
    Enum.reduce(@atom_list_fields, attrs, fn field, acc ->
      case Map.get(acc, field) do
        list when is_list(list) ->
          Map.put(acc, field, Enum.map(list, &normalize_list_element/1))

        _ ->
          acc
      end
    end)
  end

  defp normalize_list_element(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp normalize_list_element(value), do: value

  defp reject_unknown_fields(attrs) do
    unknown =
      attrs
      |> Map.keys()
      |> Enum.reject(&(&1 in @known_fields))
      |> Enum.sort_by(&inspect/1)

    if unknown == [] do
      :ok
    else
      {:error, {:unknown_contract_fields, unknown}}
    end
  end

  defp require_fields(attrs) do
    missing = Enum.reject(@required_fields, &Map.has_key?(attrs, &1))

    if missing == [] do
      :ok
    else
      {:error, {:missing_contract_fields, missing}}
    end
  end

  defp validate_read_only(%__MODULE__{read_only: true, mutation: :none}), do: :ok

  defp validate_read_only(%__MODULE__{read_only: read_only}) when read_only != true,
    do: invalid(:read_only)

  defp validate_read_only(%__MODULE__{}), do: invalid(:mutation)

  defp validate_binary(_field, value) when is_binary(value) and value != "", do: :ok
  defp validate_binary(field, _value), do: invalid(field)

  defp validate_boolean(_field, value) when is_boolean(value), do: :ok
  defp validate_boolean(field, _value), do: invalid(field)

  defp validate_atom_list(field, [_head | _tail] = list) do
    if Enum.all?(list, &is_atom/1), do: :ok, else: invalid(field)
  end

  defp validate_atom_list(field, _value), do: invalid(field)

  defp validate_aliases(aliases) when is_list(aliases) do
    if Enum.all?(aliases, &(is_binary(&1) and &1 != "")) do
      :ok
    else
      invalid(:aliases)
    end
  end

  defp validate_aliases(_aliases), do: invalid(:aliases)

  defp validate_map(_field, value) when is_map(value), do: :ok
  defp validate_map(field, _value), do: invalid(field)

  defp validate_approval(approval) when is_map(approval) do
    with :ok <- require_map_fields(:approval, approval, @approval_fields),
         false <- map_value(approval, :required),
         reason when is_binary(reason) and reason != "" <- map_value(approval, :reason) do
      :ok
    else
      true -> {:error, {:invalid_contract_approval, :required_must_be_false}}
      _reason -> {:error, {:invalid_contract_approval, :reason}}
    end
  end

  defp validate_approval(_approval), do: {:error, {:invalid_contract_approval, :not_a_map}}

  defp validate_schema(field, schema) when is_map(schema) do
    with :ok <- require_map_fields(field, schema, @schema_required_fields),
         type when type in ["object", :object] <- map_value(schema, :type),
         properties when is_map(properties) <- map_value(schema, :properties),
         required when is_list(required) <- map_value(schema, :required),
         additional when is_boolean(additional) <- map_value(schema, :additional_properties) do
      :ok
    else
      _value -> {:error, {:invalid_contract_schema, field}}
    end
  end

  defp validate_schema(field, _schema), do: {:error, {:invalid_contract_schema, field}}

  defp validate_limits(limits) when is_map(limits) do
    with :ok <- require_map_fields(:limits, limits, @limit_fields),
         paths when is_map(paths) <- map_value(limits, :paths),
         results when is_map(results) <- map_value(limits, :results),
         bytes when is_map(bytes) <- map_value(limits, :bytes),
         timeout when is_integer(timeout) and timeout > 0 <- map_value(limits, :timeout_ms) do
      :ok
    else
      _value -> {:error, {:invalid_contract_limits, :shape}}
    end
  end

  defp validate_limits(_limits), do: {:error, {:invalid_contract_limits, :not_a_map}}

  defp validate_redaction(redaction) when is_map(redaction) do
    with :ok <- require_map_fields(:redaction, redaction, @redaction_fields),
         class when is_atom(class) <- map_value(redaction, :class),
         [_head | _tail] <- map_value(redaction, :apply_before),
         rules when is_list(rules) <- map_value(redaction, :rules) do
      :ok
    else
      _value -> {:error, {:invalid_contract_redaction, :shape}}
    end
  end

  defp validate_redaction(_redaction), do: {:error, {:invalid_contract_redaction, :not_a_map}}

  defp validate_correlation(correlation) when is_map(correlation) do
    with :ok <- require_map_fields(:correlation, correlation, @correlation_fields),
         required when is_list(required) <- map_value(correlation, :required),
         optional when is_list(optional) <- map_value(correlation, :optional),
         schema when is_map(schema) <- map_value(correlation, :schema),
         [_head | _tail] <- map_value(correlation, :propagation) do
      case validate_correlation_ids(required) do
        :ok -> validate_schema(:correlation_schema, schema)
        {:error, _reason} = error -> error
      end
    else
      _value -> {:error, {:invalid_contract_correlation, :shape}}
    end
  end

  defp validate_correlation(_correlation),
    do: {:error, {:invalid_contract_correlation, :not_a_map}}

  defp validate_correlation_ids(required) do
    required_ids = ["session_id", "task_id", "tool_call_id"]

    if Enum.all?(required_ids, &(&1 in required)) do
      :ok
    else
      {:error, {:invalid_contract_correlation, :required_ids}}
    end
  end

  defp validate_execution(execution) when is_map(execution) do
    with :ok <- require_map_fields(:execution, execution, @execution_fields),
         status when is_atom(status) <- map_value(execution, :status),
         executor when is_atom(executor) <- map_value(execution, :executor),
         effects when is_list(effects) <- map_value(execution, :effects),
         false <- map_value(execution, :mutates_workspace),
         false <- map_value(execution, :mutates_store),
         false <- map_value(execution, :executes_code) do
      :ok
    else
      true -> {:error, {:invalid_contract_execution, :mutating_or_executing}}
      _value -> {:error, {:invalid_contract_execution, :shape}}
    end
  end

  defp validate_execution(_execution), do: {:error, {:invalid_contract_execution, :not_a_map}}

  defp require_map_fields(owner, map, fields) do
    missing = Enum.reject(fields, &map_has_key?(map, &1))

    if missing == [] do
      :ok
    else
      {:error, {:missing_contract_map_fields, owner, missing}}
    end
  end

  defp map_has_key?(map, key) do
    Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))
  end

  defp map_value(map, key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp invalid(field), do: {:error, {:invalid_contract_field, field}}

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {json_key(key), json_safe(item)} end)
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when value in [nil, true, false], do: value
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value), do: value

  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key), do: key
end
