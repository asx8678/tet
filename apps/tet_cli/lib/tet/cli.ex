defmodule Tet.CLI do
  @moduledoc """
  Thin standalone command-line adapter.

  The CLI parses arguments, calls the public `Tet` facade, renders output, and
  returns deterministic status codes. It does not own runtime state or storage.
  """

  alias Tet.CLI.Render

  @doc "Entrypoint used by escripts and release wrappers."
  def main(argv) do
    argv
    |> run()
    |> System.halt()
  end

  @doc "Runs a CLI command and returns a process status code."
  def run(argv) when is_list(argv) do
    case argv do
      [] ->
        IO.puts(Render.help())
        0

      ["help" | _] ->
        IO.puts(Render.help())
        0

      ["--help" | _] ->
        IO.puts(Render.help())
        0

      ["doctor" | _rest] ->
        doctor()

      ["profiles" | rest] ->
        profiles(rest)

      ["profile" | rest] ->
        profile(rest)

      ["sessions" | rest] ->
        sessions(rest)

      ["session" | rest] ->
        session(rest)

      ["events" | rest] ->
        events(rest)

      ["timeline" | rest] ->
        events(rest)

      ["ask" | args] ->
        ask(args)

      [unknown | _] ->
        IO.puts(:stderr, "unknown tet command: #{unknown}")
        IO.puts(:stderr, "run `tet help` for available scaffold commands")
        64
    end
  end

  defp doctor do
    case Tet.doctor() do
      {:ok, report} ->
        IO.puts(Render.doctor(report))
        if Map.get(report, :status, :ok) == :ok, do: 0, else: 1

      {:error, reason} ->
        IO.puts(:stderr, "tet doctor failed: #{inspect(reason)}")
        1
    end
  end

  defp profiles([]) do
    case Tet.list_profiles() do
      {:ok, profiles} ->
        IO.puts(Render.profiles(profiles))
        0

      {:error, reason} ->
        IO.puts(:stderr, "tet profiles failed: #{Render.error(reason)}")
        1
    end
  end

  defp profiles(_args) do
    IO.puts(:stderr, "usage: tet profiles")
    64
  end

  defp profile([command, profile_id]) when command in ["show", "inspect"] do
    case Tet.get_profile(profile_id) do
      {:ok, profile} ->
        IO.puts(Render.profile_show(profile))
        0

      {:error, reason} ->
        IO.puts(:stderr, "tet profile #{command} failed: #{Render.error(reason)}")
        if reason == :profile_not_found, do: 66, else: 1
    end
  end

  defp profile(_args) do
    IO.puts(:stderr, "usage: tet profile show PROFILE_ID")
    64
  end

  defp sessions([]) do
    case Tet.list_sessions() do
      {:ok, sessions} ->
        IO.puts(Render.sessions(sessions))
        0

      {:error, reason} ->
        IO.puts(:stderr, "tet sessions failed: #{Render.error(reason)}")
        1
    end
  end

  defp sessions(_args) do
    IO.puts(:stderr, "usage: tet sessions")
    64
  end

  defp session(["show", session_id]) do
    case Tet.show_session(session_id) do
      {:ok, session} ->
        IO.puts(Render.session_show(session))
        0

      {:error, reason} ->
        IO.puts(:stderr, "tet session show failed: #{Render.error(reason)}")
        if reason == :session_not_found, do: 66, else: 1
    end
  end

  defp session(_args) do
    IO.puts(:stderr, "usage: tet session show SESSION_ID")
    64
  end

  defp events(args) do
    case parse_session_filter(args) do
      {:ok, session_id} ->
        case Tet.list_events(session_id) do
          {:ok, events} ->
            IO.puts(Render.events(events))
            0

          {:error, reason} ->
            IO.puts(:stderr, "tet events failed: #{Render.error(reason)}")
            1
        end

      {:error, message} ->
        IO.puts(:stderr, message)
        IO.puts(:stderr, "usage: tet events [--session SESSION_ID]")
        64
    end
  end

  defp ask(args) do
    case parse_ask(args, []) do
      {:ok, opts, prompt_parts} ->
        prompt = prompt_parts |> Enum.join(" ") |> String.trim()

        if prompt == "" do
          IO.puts(:stderr, "usage: tet ask [--session SESSION_ID] PROMPT")
          64
        else
          run_ask(prompt, opts)
        end

      {:error, message} ->
        IO.puts(:stderr, message)
        IO.puts(:stderr, "usage: tet ask [--session SESSION_ID] PROMPT")
        64
    end
  end

  defp parse_ask([], opts), do: {:ok, Enum.reverse(opts), []}

  defp parse_ask(["--" | prompt_parts], opts), do: {:ok, Enum.reverse(opts), prompt_parts}

  defp parse_ask(["--session", session_id | rest], opts) do
    session_id = String.trim(session_id)

    if session_id == "" do
      {:error, "--session requires a non-empty session id"}
    else
      parse_ask(rest, [{:session_id, session_id} | opts])
    end
  end

  defp parse_ask(["--session"], _opts), do: {:error, "--session requires a session id"}

  defp parse_ask(["--session=" <> session_id | rest], opts) do
    session_id = String.trim(session_id)

    if session_id == "" do
      {:error, "--session requires a non-empty session id"}
    else
      parse_ask(rest, [{:session_id, session_id} | opts])
    end
  end

  defp parse_ask(prompt_parts, opts), do: {:ok, Enum.reverse(opts), prompt_parts}

  defp parse_session_filter([]), do: {:ok, nil}

  defp parse_session_filter(["--session", session_id]) do
    session_id = String.trim(session_id)

    if session_id == "" do
      {:error, "--session requires a non-empty session id"}
    else
      {:ok, session_id}
    end
  end

  defp parse_session_filter(["--session"]), do: {:error, "--session requires a session id"}

  defp parse_session_filter(["--session=" <> session_id]) do
    session_id = String.trim(session_id)

    if session_id == "" do
      {:error, "--session requires a non-empty session id"}
    else
      {:ok, session_id}
    end
  end

  defp parse_session_filter(_args), do: {:error, "unknown tet events option"}

  defp run_ask(prompt, opts) do
    on_event = fn event ->
      case Render.stream_event(event) do
        nil -> :ok
        chunk -> IO.write(chunk)
      end
    end

    case Tet.ask(prompt, Keyword.put(opts, :on_event, on_event)) do
      {:ok, _result} ->
        IO.write("\n")
        0

      {:error, reason} ->
        IO.puts(:stderr, "tet ask failed: #{Render.error(reason)}")
        1
    end
  end
end
