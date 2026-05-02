defmodule Tet.Docs do
  @moduledoc """
  Documentation registry for TET — BD-0073.

  Provides topic-based lookup, search across all topics, and aggregated
  lists of CLI commands, safety warnings, and verification commands.
  """

  alias Tet.Docs.Topic

  @doc "Returns all topic structs."
  @spec topics() :: [Topic.t()]
  def topics do
    Topic.build_all()
  end

  @doc """
  Retrieves a single topic by its atom ID.

  Returns `{:ok, topic}` or `:error` if the topic does not exist.
  """
  @spec get(atom()) :: {:ok, Topic.t()} | :error
  def get(id) when is_atom(id) do
    if id in Topic.topics() do
      {:ok, Topic.build(id)}
    else
      :error
    end
  end

  @doc """
  Searches all topics for a given string, matching against title and content.

  Returns a list of matching topic structs. Case-insensitive substring match.
  """
  @spec search(String.t()) :: [Topic.t()]
  def search(query) when is_binary(query) do
    lower = String.downcase(query)

    Topic.build_all()
    |> Enum.filter(fn topic ->
      String.contains?(String.downcase(topic.title), lower) or
        String.contains?(String.downcase(topic.content), lower)
    end)
  end

  @doc """
  Returns a flat list of all unique CLI commands across all topics.
  """
  @spec commands() :: [String.t()]
  def commands do
    Topic.build_all()
    |> Enum.flat_map(& &1.related_commands)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Returns a flat list of all unique safety warnings across all topics.
  """
  @spec safety_warnings() :: [String.t()]
  def safety_warnings do
    Topic.build_all()
    |> Enum.flat_map(& &1.safety_warnings)
    |> Enum.uniq()
  end

  @doc """
  Returns a flat list of all unique verification commands across all topics.
  """
  @spec verification_commands() :: [String.t()]
  def verification_commands do
    Topic.build_all()
    |> Enum.flat_map(& &1.verification_commands)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
