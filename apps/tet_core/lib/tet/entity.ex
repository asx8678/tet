defmodule Tet.Entity do
  @moduledoc false

  @type attrs :: map()
  @type field :: atom()
  @type reason ::
          {:invalid_entity_field, atom(), atom()} | {:invalid_entity_value, atom(), atom()}

  @spec fetch_value(attrs(), field(), term()) :: term()
  def fetch_value(attrs, key, default \\ nil) when is_map(attrs) and is_atom(key) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  @spec fetch_required_binary(attrs(), field(), atom()) :: {:ok, binary()} | {:error, reason()}
  def fetch_required_binary(attrs, key, entity) do
    case fetch_value(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> field_error(entity, key)
    end
  end

  @spec fetch_optional_binary(attrs(), field(), atom()) ::
          {:ok, binary() | nil} | {:error, reason()}
  def fetch_optional_binary(attrs, key, entity) do
    case fetch_value(attrs, key) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _value -> field_error(entity, key)
    end
  end

  @spec fetch_binary_or_nil(attrs(), field(), atom()) ::
          {:ok, binary() | nil} | {:error, reason()}
  def fetch_binary_or_nil(attrs, key, entity) do
    case fetch_value(attrs, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _value -> field_error(entity, key)
    end
  end

  @spec fetch_required_datetime(attrs(), field(), atom()) ::
          {:ok, DateTime.t()} | {:error, term()}
  def fetch_required_datetime(attrs, key, entity) do
    attrs
    |> fetch_value(key)
    |> normalize_datetime(entity, key, required?: true)
  end

  @spec fetch_optional_datetime(attrs(), field(), atom()) ::
          {:ok, DateTime.t() | nil} | {:error, term()}
  def fetch_optional_datetime(attrs, key, entity) do
    attrs
    |> fetch_value(key)
    |> normalize_datetime(entity, key, required?: false)
  end

  @spec fetch_atom(attrs(), field(), [atom()], atom()) :: {:ok, atom()} | {:error, reason()}
  def fetch_atom(attrs, key, allowed, entity) when is_list(allowed) do
    case fetch_value(attrs, key) do
      value when is_atom(value) ->
        if value in allowed do
          {:ok, value}
        else
          value_error(entity, key)
        end

      value when is_binary(value) ->
        case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
          nil -> value_error(entity, key)
          atom -> {:ok, atom}
        end

      _value ->
        field_error(entity, key)
    end
  end

  @spec fetch_optional_existing_atom(attrs(), field(), atom()) ::
          {:ok, atom() | nil} | {:error, reason()}
  def fetch_optional_existing_atom(attrs, key, entity) do
    case fetch_value(attrs, key) do
      nil ->
        {:ok, nil}

      "" ->
        {:ok, nil}

      value when is_atom(value) ->
        {:ok, value}

      value when is_binary(value) ->
        existing_atom(value, entity, key)

      _value ->
        field_error(entity, key)
    end
  end

  @spec fetch_map(attrs(), field(), atom()) :: {:ok, map()} | {:error, reason()}
  def fetch_map(attrs, key, entity) do
    case fetch_value(attrs, key, %{}) do
      value when is_map(value) -> {:ok, value}
      _value -> field_error(entity, key)
    end
  end

  @spec fetch_list(attrs(), field(), atom()) :: {:ok, list()} | {:error, reason()}
  def fetch_list(attrs, key, entity) do
    case fetch_value(attrs, key, []) do
      value when is_list(value) -> {:ok, value}
      _value -> field_error(entity, key)
    end
  end

  @spec fetch_string_list(attrs(), field(), atom()) :: {:ok, [binary()]} | {:error, reason()}
  def fetch_string_list(attrs, key, entity) do
    with {:ok, values} <- fetch_list(attrs, key, entity),
         true <- Enum.all?(values, &is_binary/1) do
      {:ok, values}
    else
      false -> value_error(entity, key)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec fetch_positive_integer(attrs(), field(), atom(), pos_integer()) ::
          {:ok, pos_integer()} | {:error, reason()}
  def fetch_positive_integer(attrs, key, entity, default \\ 1)
      when is_integer(default) and default > 0 do
    case fetch_value(attrs, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _value -> field_error(entity, key)
    end
  end

  @spec fetch_sha256(attrs(), field(), atom()) :: {:ok, binary()} | {:error, reason()}
  def fetch_sha256(attrs, key, entity) do
    with {:ok, value} <- fetch_required_binary(attrs, key, entity),
         true <- sha256?(value) do
      {:ok, value}
    else
      false -> value_error(entity, key)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec datetime_to_map(DateTime.t() | nil) :: binary() | nil
  def datetime_to_map(nil), do: nil
  def datetime_to_map(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  @spec atom_to_map(atom() | nil) :: binary() | nil
  def atom_to_map(nil), do: nil
  def atom_to_map(value) when is_atom(value), do: Atom.to_string(value)

  @spec field_error(atom(), field()) :: {:error, reason()}
  def field_error(entity, key), do: {:error, {:invalid_entity_field, entity, key}}

  @spec value_error(atom(), field()) :: {:error, reason()}
  def value_error(entity, key), do: {:error, {:invalid_entity_value, entity, key}}

  defp normalize_datetime(nil, entity, key, required?: true), do: field_error(entity, key)
  defp normalize_datetime(nil, _entity, _key, required?: false), do: {:ok, nil}
  defp normalize_datetime("", entity, key, required?: true), do: field_error(entity, key)
  defp normalize_datetime("", _entity, _key, required?: false), do: {:ok, nil}
  defp normalize_datetime(%DateTime{} = datetime, _entity, _key, _opts), do: {:ok, datetime}

  defp normalize_datetime(value, entity, key, _opts) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> value_error(entity, key)
    end
  end

  defp normalize_datetime(_value, entity, key, _opts), do: field_error(entity, key)

  defp existing_atom(value, entity, key) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> value_error(entity, key)
  end

  defp sha256?(value) when byte_size(value) == 64 do
    String.match?(value, ~r/\A[0-9a-f]{64}\z/)
  end

  defp sha256?(_value), do: false
end
