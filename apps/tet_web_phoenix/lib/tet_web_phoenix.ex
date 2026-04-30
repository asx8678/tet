defmodule TetWebPhoenix do
  @moduledoc """
  Dependency-free shell for the optional Phoenix adapter.

  The modules in this application are intentionally boring projection helpers:
  they load timeline records through the public `Tet` facade, reshape those
  `%Tet.Event{}` records into dashboard rows, and render static HTML that a real
  Phoenix LiveView can wrap later.

  No endpoint, router, PubSub, persistence, policy, provider, tool execution, or
  mutable domain state lives here. Glamorous? No. Removable? Heck yes.
  """

  alias TetWebPhoenix.Dashboard

  @doc "Returns the dashboard identifiers exposed by the optional adapter shell."
  def dashboard_names, do: Dashboard.names()

  @doc "Loads one dashboard projection through the public facade."
  def dashboard(name, opts \\ []), do: Dashboard.load(name, opts)

  @doc "Loads and renders one dashboard as dependency-free HTML."
  def render_dashboard(name, opts \\ []), do: Dashboard.render(name, opts)
end
