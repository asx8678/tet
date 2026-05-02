defmodule Tet.Store.SQLite.Schema.JsonField do
  @moduledoc """
  Shared JSON blob encode/decode helpers for SQLite BLOB columns.

  SQLite stores JSON-ish data as BLOB — `X'7B7D'` for `{}`, `X'5B5D'` for `[]`.
  This module handles the round-trip without scattering Jason calls across
  every schema like breadcrumbs in a forest of encoding gremlins.
  """

  @doc "Encodes an Elixir term to a JSON binary suitable for BLOB storage."
  @spec encode(term()) :: binary()
  def encode(value) when is_map(value) or is_list(value), do: Jason.encode!(value)
  def encode(value) when is_binary(value), do: value
  def encode(nil), do: "{}"

  @doc "Decodes a JSON binary blob to an Elixir map. Returns `%{}` on nil or failure."
  @spec decode(binary() | nil) :: map()
  def decode(nil), do: %{}

  def decode(blob) when is_binary(blob) do
    case Jason.decode(blob) do
      {:ok, value} when is_map(value) -> value
      {:ok, _other} -> %{}
      {:error, _} -> %{}
    end
  end

  @doc "Decodes a JSON binary blob to an Elixir list. Returns `[]` on nil or failure."
  @spec decode_list(binary() | nil) :: list()
  def decode_list(nil), do: []

  def decode_list(blob) when is_binary(blob) do
    case Jason.decode(blob) do
      {:ok, value} when is_list(value) -> value
      {:ok, _other} -> []
      {:error, _} -> []
    end
  end

  @doc "Decodes a JSON binary blob permissively — maps, lists, or scalars."
  @spec decode_any(binary() | nil) :: term()
  def decode_any(nil), do: nil

  def decode_any(blob) when is_binary(blob) do
    case Jason.decode(blob) do
      {:ok, value} -> value
      {:error, _} -> nil
    end
  end

  @doc "Converts a Unix epoch integer to a `DateTime`, or returns nil."
  @spec to_datetime(integer() | nil) :: DateTime.t() | nil
  def to_datetime(nil), do: nil
  def to_datetime(unix) when is_integer(unix), do: DateTime.from_unix!(unix)

  @doc "Converts a `DateTime` to Unix epoch seconds, or returns nil."
  @spec from_datetime(DateTime.t() | integer() | nil) :: integer() | nil
  def from_datetime(nil), do: nil
  def from_datetime(%DateTime{} = dt), do: DateTime.to_unix(dt)
  def from_datetime(unix) when is_integer(unix), do: unix
end
