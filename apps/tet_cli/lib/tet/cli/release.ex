defmodule Tet.CLI.Release do
  @moduledoc false

  def main(["--" | argv]) do
    Tet.CLI.main(argv)
  end

  def main(argv) when is_list(argv) do
    Tet.CLI.main(argv)
  end
end
