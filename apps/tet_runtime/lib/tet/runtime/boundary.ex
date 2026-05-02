defmodule Tet.Runtime.Boundary do
  @moduledoc """
  Standalone release boundary helpers.

  These helpers keep the release/application closure explicit and give tests a
  single place to reject accidental web-adapter drift.

  Forbidden application lists are sourced from `Tet.Release` (the canonical
  authority) rather than duplicated here, to prevent stale drift.
  """

  alias Tet.Release

  @standalone_applications [:tet_core, :tet_store_sqlite, :tet_runtime, :tet_cli]

  @optional_adapter_applications [:tet_web_phoenix]

  @doc "Returns the applications that may make up the standalone release."
  def standalone_applications do
    Application.get_env(:tet_runtime, :standalone_applications, @standalone_applications)
  end

  @doc "Returns optional adapter applications that may be loaded in umbrella development."
  def optional_adapter_applications, do: @optional_adapter_applications

  @doc "Returns boundary metadata for docs, CLI doctor, and tests."
  def standalone do
    %{
      release: :tet_standalone,
      applications: standalone_applications(),
      excludes: [:tet_web_phoenix, :phoenix, :phoenix_live_view, :plug, :cowboy]
    }
  end

  @doc "Validates that an application list contains no forbidden web apps."
  def validate_standalone_applications(applications) when is_list(applications) do
    leaked = Enum.filter(applications, &forbidden_application?/1)

    if leaked == [] do
      :ok
    else
      {:error, {:forbidden_standalone_applications, leaked}}
    end
  end

  @doc "Returns forbidden applications from a loaded/started application tuple list."
  def forbidden_loaded_applications(applications, opts \\ []) when is_list(applications) do
    ignored = Keyword.get(opts, :ignore, [])

    applications
    |> Enum.map(&application_name/1)
    |> Enum.filter(&forbidden_application?/1)
    |> Enum.reject(&(&1 in ignored))
  end

  @doc "True when an application atom belongs to a web framework or web adapter."
  def forbidden_application?(application) when is_atom(application) do
    name = Atom.to_string(application)

    application in Release.forbidden_standalone_exact() or
      Enum.any?(Release.forbidden_standalone_prefixes(), &String.starts_with?(name, &1))
  end

  defp application_name({application, _description, _version}), do: application
  defp application_name(application) when is_atom(application), do: application
end
