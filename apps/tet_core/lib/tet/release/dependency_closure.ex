defmodule Tet.Release.DependencyClosure do
  @moduledoc """
  Computes dependency closures for release modes.

  Uses the umbrella-internal dependency graph defined in `Tet.Release` to
  compute transitive closures, find overlaps, and verify that standalone
  releases never pull in web dependencies.
  """

  alias Tet.Release

  # ── Public API ───────────────────────────────────────────────────────────

  @doc """
  Given a list of umbrella app names, returns the full transitive
  dependency closure (including the apps themselves).

  ## Example

      iex> DependencyClosure.compute([:tet_cli])
      [:tet_core, :tet_runtime, :tet_cli]
  """
  @spec compute([atom()]) :: [atom()]
  def compute(apps) when is_list(apps) do
    graph = Release.umbrella_dep_graph()
    do_compute(apps, graph, MapSet.new())
  end

  @doc """
  Finds deps shared between two dependency closures.
  Returns a sorted list of overlapping app names.
  """
  @spec overlap([atom()], [atom()]) :: [atom()]
  def overlap(closure_a, closure_b) do
    set_a = MapSet.new(closure_a)
    set_b = MapSet.new(closure_b)

    MapSet.intersection(set_a, set_b)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  @doc """
  Finds deps exclusive to `closure_a` (not present in `closure_b`).
  Returns a sorted list.
  """
  @spec exclusive([atom()], [atom()]) :: [atom()]
  def exclusive(closure_a, closure_b) do
    set_a = MapSet.new(closure_a)
    set_b = MapSet.new(closure_b)

    MapSet.difference(set_a, set_b)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  @doc """
  Verifies that the standalone dependency closure does not contain
  any web applications. Returns `:ok` or `{:error, [String.t()]}`.
  """
  @spec verify_no_web_in_standalone() :: :ok | {:error, [String.t()]}
  def verify_no_web_in_standalone do
    standalone_closure = compute(Release.standalone_apps())
    web_apps = Release.web_apps()
    forbidden_exact = Release.forbidden_standalone_exact()
    forbidden_prefixes = Release.forbidden_standalone_prefixes()

    leaked =
      Enum.filter(standalone_closure, fn app ->
        app in web_apps or app in forbidden_exact or
          Enum.any?(forbidden_prefixes, &String.starts_with?(Atom.to_string(app), &1))
      end)

    case leaked do
      [] -> :ok
      _ -> {:error, ["standalone closure leaked web deps: #{inspect(Enum.sort(leaked))}"]}
    end
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp do_compute([], _graph, visited), do: MapSet.to_list(visited) |> Enum.sort()

  defp do_compute([app | rest], graph, visited) do
    if MapSet.member?(visited, app) do
      do_compute(rest, graph, visited)
    else
      visited = MapSet.put(visited, app)
      direct_deps = Map.get(graph, app, [])
      do_compute(direct_deps ++ rest, graph, visited)
    end
  end
end
