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
    configured_path = StoreConfig.path(opts)
    env_path = System.get_env("TET_STORE_PATH")

    case StoreConfig.health(opts) do
      {:ok, health} ->
        case validate_configured_store_path(env_path, health) do
          :ok ->
            message = store_health_message(health)
            checked(:store, message, health)

          {:error, reason} ->
            details =
              health
              |> Map.put(:status, :error)
              |> Map.put(:path, configured_path)

            errored(:store, reason, details)
        end

      {:error, reason} ->
        details = %{
          application: :none,
          adapter: StoreConfig.adapter(opts),
          path: configured_path,
          status: :error,
          reason: reason
        }

        errored(:store, "store health check failed: #{inspect(reason)}", details)
    end
  end

  @doc false
  def validate_configured_store_path(nil, _health), do: :ok
  def validate_configured_store_path("", _health), do: :ok

  def validate_configured_store_path(path, health) when is_binary(path) do
    cond do
      health[:dir_exists?] == false ->
        {:error,
         "store path does not exist or is not a directory: #{path} — check TET_STORE_PATH"}

      health[:writable?] == false ->
        {:error, "store path is not writable: #{path} — check permissions and TET_STORE_PATH"}

      true ->
        :ok
    end
  end

  def validate_configured_store_path(_path, _health), do: :ok

  @doc """
  Builds the human-readable store health check message.

  SQLite health maps with `format: :sqlite`, a binary `journal_mode`, and an integer
  `schema_version` get SQLite-specific messaging. Other adapters fall back to the
  generic store-health message.
  """
  @spec store_health_message(map()) :: String.t()
  def store_health_message(%{format: :sqlite, journal_mode: jm, schema_version: sv})
      when is_binary(jm) and is_integer(sv) do
    "SQLite store healthy (#{String.upcase(jm)} mode, schema v#{sv})"
  end

  def store_health_message(_health), do: "store path is readable and writable"

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

    loaded_leaks =
      Boundary.forbidden_loaded_applications(Application.loaded_applications(),
        ignore: Boundary.optional_adapter_applications()
      )

    started_leaks =
      Boundary.forbidden_loaded_applications(Application.started_applications(),
        ignore: Boundary.optional_adapter_applications()
      )

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
