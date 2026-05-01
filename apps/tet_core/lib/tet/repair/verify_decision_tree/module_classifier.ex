defmodule Tet.Repair.VerifyDecisionTree.ModuleClassifier do
  @moduledoc """
  Classifies modules by hot-reload safety — BD-0061.

  Determines whether a changed module can be safely hot-reloaded in place
  or requires a full application restart. Classification uses module name
  patterns and behaviour/attribute detection when module info is available.

  Safety tiers:
  - `:safe_reload` — pure functions, data structs, helpers
  - `:unsafe_reload` — GenServers, Supervisors, Application modules, migrations
  - `:unknown` — anything we can't confidently classify → defaults to restart

  This module is pure functions only. No side effects.
  """

  @type classification :: :safe_reload | :unsafe_reload | :unknown

  @safe_suffixes ~w(Helper Helpers Utils Util Schema Struct View Formatter Parser Validator)
  @safe_infixes ~w(Helper Helpers Utils Util)

  @unsafe_suffixes ~w(Server Supervisor Worker Application Migration GenServer Registry Agent)
  @unsafe_infixes ~w(Server Supervisor Worker Application Migration Registry Agent)

  @unsafe_behaviours [GenServer, Supervisor, Application, GenEvent, :gen_statem]

  @doc """
  Classifies a module as safe, unsafe, or unknown for hot-reload.

  Accepts a module atom, a string module name, or a file path.

  ## Examples

      iex> ModuleClassifier.classify(MyApp.Helpers.StringUtils)
      :safe_reload

      iex> ModuleClassifier.classify(MyApp.OrderServer)
      :unsafe_reload

      iex> ModuleClassifier.classify(MyApp.SomeWeirdThing)
      :unknown
  """
  @spec classify(atom() | String.t()) :: classification()
  def classify(module) when is_atom(module) do
    module
    |> module_name_string()
    |> classify_by_name()
    |> maybe_refine_with_behaviours(module)
  end

  def classify(module_or_path) when is_binary(module_or_path) do
    module_or_path
    |> normalize_to_module_name()
    |> classify_by_name()
  end

  @doc """
  Returns patterns that indicate a module is safe to hot-reload.

  These are suffix and infix patterns matched against the final segment
  of a module's fully-qualified name.
  """
  @spec safe_patterns() :: %{suffixes: [String.t()], infixes: [String.t()]}
  def safe_patterns do
    %{suffixes: @safe_suffixes, infixes: @safe_infixes}
  end

  @doc """
  Returns patterns that indicate a module requires a full restart.

  These are suffix and infix patterns matched against the final segment
  of a module's fully-qualified name.
  """
  @spec unsafe_patterns() :: %{suffixes: [String.t()], infixes: [String.t()]}
  def unsafe_patterns do
    %{suffixes: @unsafe_suffixes, infixes: @unsafe_infixes}
  end

  # -- Private --

  defp module_name_string(module) when is_atom(module) do
    module |> Atom.to_string() |> String.replace_leading("Elixir.", "")
  end

  defp normalize_to_module_name(str) do
    if String.contains?(str, "/") do
      file_path_to_module_name(str)
    else
      str
    end
  end

  defp file_path_to_module_name(path) do
    path
    |> String.replace(~r{^.*/lib/}, "")
    |> String.replace(~r{\.ex$}, "")
    |> String.split("/")
    |> Enum.map(&Macro.camelize/1)
    |> Enum.join(".")
  end

  defp classify_by_name(module_name) do
    segments = String.split(module_name, ".")
    last_segment = List.last(segments) || ""

    cond do
      matches_unsafe?(last_segment, segments) -> :unsafe_reload
      matches_safe?(last_segment, segments) -> :safe_reload
      true -> :unknown
    end
  end

  defp matches_unsafe?(last_segment, segments) do
    suffix_match?(last_segment, @unsafe_suffixes) or
      infix_match?(segments, @unsafe_infixes)
  end

  defp matches_safe?(last_segment, segments) do
    suffix_match?(last_segment, @safe_suffixes) or
      infix_match?(segments, @safe_infixes)
  end

  defp suffix_match?(segment, suffixes) do
    Enum.any?(suffixes, fn suffix ->
      String.ends_with?(segment, suffix) or segment == suffix
    end)
  end

  defp infix_match?(segments, infixes) do
    Enum.any?(segments, fn segment ->
      Enum.any?(infixes, fn infix -> segment == infix end)
    end)
  end

  defp maybe_refine_with_behaviours(:unknown, module) do
    if Code.ensure_loaded?(module) do
      behaviours = get_behaviours(module)

      cond do
        has_unsafe_behaviour?(behaviours) -> :unsafe_reload
        has_struct?(module) -> :safe_reload
        true -> :unknown
      end
    else
      :unknown
    end
  end

  defp maybe_refine_with_behaviours(classification, _module), do: classification

  defp get_behaviours(module) do
    if function_exported?(module, :__info__, 1) do
      module.__info__(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()
    else
      []
    end
  rescue
    _ -> []
  end

  defp has_unsafe_behaviour?(behaviours) do
    Enum.any?(behaviours, &(&1 in @unsafe_behaviours))
  end

  defp has_struct?(module) do
    function_exported?(module, :__struct__, 0)
  end
end
