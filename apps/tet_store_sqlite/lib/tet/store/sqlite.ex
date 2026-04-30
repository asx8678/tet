defmodule Tet.Store.SQLite do
  @moduledoc """
  Default standalone store boundary placeholder.

  The application is deliberately dependency-free for this issue. Later store
  tickets can add schemas, migrations, and database packages behind the
  `Tet.Store` behaviour without changing the release boundary.
  """

  @behaviour Tet.Store

  @default_path ".tet/tet.sqlite"

  @impl true
  def boundary do
    %{
      application: :tet_store_sqlite,
      adapter: __MODULE__,
      status: :boundary_only,
      path: @default_path
    }
  end

  @impl true
  def health(opts) when is_list(opts) do
    path = Keyword.get(opts, :path, @default_path)

    {:ok,
     boundary()
     |> Map.put(:path, path)
     |> Map.put(:started?, started?())}
  end

  defp started? do
    Enum.any?(Application.started_applications(), fn {application, _description, _version} ->
      application == :tet_store_sqlite
    end)
  end
end
