defmodule Tet.Runtime.Doctor do
  @moduledoc """
  Runtime health diagnostics for the standalone CLI.

  Doctor reports should be useful even when one check fails. Returning a report
  with an error status beats face-planting before telling the user what to fix.
  """

  alias Tet.Runtime.{Boundary, ProviderConfig, StoreConfig}

  @doc "Runs standalone diagnostics for config, store, provider, and boundary."
  def run(opts \\ []) when is_list(opts) do
    applications = Boundary.standalone_applications()

    config = config_check(opts, applications)
    store = store_check(opts)
    provider = provider_check(opts)
    release = release_boundary_check(applications)
    checks = [config.check, store.check, provider.check, release.check]

    {:ok,
     %{
       status: overall_status(checks),
       profile: Application.get_env(:tet_runtime, :release_profile, :tet_standalone),
       applications: applications,
       core: Tet.Core.boundary(),
       runtime: %{application: :tet_runtime, status: :ok},
       config: config.details,
       store: store.details,
       provider: provider.details,
       release_boundary: release.details,
       checks: checks
     }}
  end

  defp config_check(opts, applications) do
    profile = Application.get_env(:tet_runtime, :release_profile, :tet_standalone)
    store_adapter = StoreConfig.adapter(opts)
    store_path = StoreConfig.path(opts)
    provider = ProviderConfig.provider_name(opts)

    cond do
      is_nil(store_adapter) ->
        errored(:config, "store adapter is not configured", %{
          profile: profile,
          applications: applications,
          store_adapter: nil,
          store_path: store_path,
          provider: provider
        })

      is_nil(store_path) or store_path == "" ->
        errored(:config, "store path is not configured", %{
          profile: profile,
          applications: applications,
          store_adapter: store_adapter,
          store_path: store_path,
          provider: provider
        })

      true ->
        checked(:config, "runtime config loaded", %{
          profile: profile,
          applications: applications,
          store_adapter: store_adapter,
          store_path: store_path,
          provider: provider
        })
    end
  end

  defp store_check(opts) do
    case StoreConfig.health(opts) do
      {:ok, health} ->
        checked(:store, "store path is readable and writable", health)

      {:error, reason} ->
        details = %{
          application: :none,
          adapter: StoreConfig.adapter(opts),
          path: StoreConfig.path(opts),
          status: :error,
          reason: reason
        }

        errored(:store, "store health check failed: #{inspect(reason)}", details)
    end
  end

  defp provider_check(opts) do
    case ProviderConfig.diagnose(opts) do
      {:ok, details} -> checked(:provider, details.message, details)
      {:error, details} -> errored(:provider, details.message, details)
    end
  end

  defp release_boundary_check(applications) do
    configured_leaks =
      case Boundary.validate_standalone_applications(applications) do
        :ok -> []
        {:error, {:forbidden_standalone_applications, leaked}} -> leaked
      end

    loaded_leaks = Boundary.forbidden_loaded_applications(Application.loaded_applications())
    started_leaks = Boundary.forbidden_loaded_applications(Application.started_applications())
    leaks = Enum.uniq(configured_leaks ++ loaded_leaks ++ started_leaks)

    details = %{
      status: if(leaks == [], do: :ok, else: :error),
      applications: applications,
      configured_forbidden: configured_leaks,
      loaded_forbidden: loaded_leaks,
      started_forbidden: started_leaks,
      forbidden: leaks
    }

    if leaks == [] do
      checked(:release_boundary, "standalone closure excludes web applications", details)
    else
      errored(:release_boundary, "forbidden applications detected: #{inspect(leaks)}", details)
    end
  end

  defp checked(name, message, details) do
    details = Map.put(details, :status, Map.get(details, :status, :ok))
    %{check: %{name: name, status: :ok, message: message}, details: details}
  end

  defp errored(name, message, details) do
    details = Map.put(details, :status, :error)
    %{check: %{name: name, status: :error, message: message}, details: details}
  end

  defp overall_status(checks) do
    if Enum.any?(checks, &(&1.status == :error)), do: :error, else: :ok
  end
end
