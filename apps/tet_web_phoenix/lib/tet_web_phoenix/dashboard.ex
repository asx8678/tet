defmodule TetWebPhoenix.Dashboard do
  @moduledoc """
  Dashboard registry for the optional web adapter shell.

  Dashboard modules are presentation adapters over Event Log records. A future
  LiveView can call `load/2` for assigns or `render/2` for the dependency-free
  HTML fallback without moving state ownership into the web layer.
  """

  alias TetWebPhoenix.Dashboards.{Artifacts, RemoteStatus, RepairStatus, Tasks, Timeline}

  @dashboards %{
    timeline: Timeline,
    tasks: Tasks,
    artifacts: Artifacts,
    repair: RepairStatus,
    remote_status: RemoteStatus
  }

  @aliases %{
    "timeline" => :timeline,
    "tasks" => :tasks,
    "artifacts" => :artifacts,
    "repair" => :repair,
    "repair_status" => :repair,
    "remote" => :remote_status,
    "remote_status" => :remote_status
  }

  @doc "Returns canonical dashboard identifiers."
  def names do
    [:timeline, :tasks, :artifacts, :repair, :remote_status]
  end

  @doc "Loads a dashboard projection by atom or string identifier."
  def load(name, opts \\ []) when is_list(opts) do
    with {:ok, module} <- dashboard_module(name) do
      module.load(opts)
    end
  end

  @doc "Loads and renders a dashboard by atom or string identifier."
  def render(name, opts \\ []) when is_list(opts) do
    with {:ok, module} <- dashboard_module(name) do
      module.render(opts)
    end
  end

  @doc "Returns a LiveView-friendly assigns map without depending on LiveView."
  def assigns(name, opts \\ []) when is_list(opts) do
    with {:ok, module} <- dashboard_module(name),
         {:ok, projection} <- module.load(opts) do
      {:ok, %{dashboard: projection, html: module.render_projection(projection)}}
    end
  end

  defp dashboard_module(name) when is_atom(name) do
    case Map.fetch(@dashboards, name) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unknown_dashboard, name}}
    end
  end

  defp dashboard_module(name) when is_binary(name) do
    case Map.fetch(@aliases, String.trim(name)) do
      {:ok, canonical} -> dashboard_module(canonical)
      :error -> {:error, {:unknown_dashboard, name}}
    end
  end

  defp dashboard_module(name), do: {:error, {:unknown_dashboard, name}}
end
