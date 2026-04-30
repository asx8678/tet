defmodule Tet.CLI.Render do
  @moduledoc false

  def help do
    """
    tet - standalone Tet CLI scaffold

    Commands:
      tet doctor   Check the standalone CLI/runtime/core/store boundary
      tet help     Show this help
    """
  end

  def doctor(%{profile: profile, applications: applications, store: store}) do
    application_list = applications |> Enum.map(&Atom.to_string/1) |> Enum.join(", ")
    store_status = Map.get(store, :status, :unknown)
    store_path = Map.get(store, :path, "n/a")

    """
    Tet standalone doctor: ok
    profile: #{profile}
    applications: #{application_list}
    store: #{inspect(store.adapter)} (#{store_status})
    store_path: #{store_path}
    """
  end
end
