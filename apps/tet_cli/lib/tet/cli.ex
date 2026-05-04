defmodule Tet.CLI do
  @moduledoc """
  Thin standalone command-line adapter.

  The CLI parses arguments, calls the public `Tet` facade, renders output, and
  returns deterministic status codes. It does not own runtime state or storage.
  """

  alias Tet.CLI.{Completion, HelpFormatter, History, Render}
  alias Tet.Docs
  alias Tet.Docs.Topic

  @known_topics Topic.string_to_id()

  @doc "Entrypoint used by escripts and release wrappers."
  def main(argv) do
    argv
    |> run()
    |> System.halt()
  end

  @doc "Runs a CLI command and returns a process status code."
  def run(argv) when is_list(argv) do
    # Ensure OTP applications are started. This is required when running via
    # a release `eval` command (used by the `tet` wrapper) which boots with
    # `start_clean` and does not start application supervisors automatically.
    # In dev/test, the apps are already started so this is a harmless no-op.
    Application.ensure_all_started(:tet_store_sqlite)
    Application.ensure_all_started(:tet_runtime)

    case argv do
      [] ->
        IO.puts(Render.help())
        0

      ["help"] ->
        IO.puts(Render.help())
        topic_names = Enum.join(Map.keys(@known_topics), ", ")
        IO.puts("\nAvailable help topics: #{topic_names}")
        0

      ["help", "topics"] ->
        IO.puts("Available help topics:\n")

        for {name, id} <- Enum.sort(Map.to_list(@known_topics)) do
          {:ok, topic} = Docs.get(id)
          IO.puts("  #{name} - #{topic.title}")
        end

        0

      ["help", topic_str] ->
        case Map.get(@known_topics, topic_str) do
          nil ->
            IO.puts(:stderr, "unknown help topic: #{topic_str}")
            topic_names = Enum.join(Map.keys(@known_topics), ", ")
            IO.puts(:stderr, "available topics: #{topic_names}")
            64

          topic_id ->
            {:ok, topic} = Docs.get(topic_id)
            IO.puts(HelpFormatter.format_topic(topic))
            0
        end

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

      ["completion" | rest] ->
        completion(rest)

      ["history" | rest] ->
        history(rest)

      ["ask" | args] ->
        ask(args)

      ["prompt-lab" | rest] ->
        prompt_lab(rest)

      ["correct" | args] ->
        correct(args)

      [unknown | _] ->
        IO.puts(:stderr, "unknown tet command: #{unknown}")
        suggest_closest_command(unknown)
        IO.puts(:stderr, "run `tet help` for available scaffold commands")
        64
    end
  end

  @known_commands ~w(ask profiles profile sessions session events timeline
                     completion history doctor prompt-lab correct help)

  defp suggest_closest_command(unknown) do
    @known_commands
    |> Enum.map(fn cmd -> {cmd, String.jaro_distance(unknown, cmd)} end)
    |> Enum.reject(fn {_cmd, dist} -> dist < 0.6 end)
    |> Enum.sort_by(fn {_cmd, dist} -> -dist end)
    |> Enum.take(3)
    |> case do
      [] ->
        :ok

      suggestions ->
        hint = suggestions |> Enum.map(fn {cmd, _} -> "`#{cmd}`" end) |> Enum.join(", ")
        IO.puts(:stderr, "did you mean: #{hint}?")
    end
  end

  defp doctor do
    case Tet.doctor() do
      {:ok, report} ->
        IO.puts(Render.doctor(report))
        if Map.get(report, :status, :ok) == :ok, do: 0, else: 1

      {:error, reason} ->
        IO.puts(:stderr, "tet doctor failed: #{Render.error(reason)}")
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

      {:error, :profile_not_found} ->
        IO.puts(:stderr, "tet profile #{command} failed: profile '#{profile_id}' not found")

        case Tet.list_profiles() do
          {:ok, profiles} when profiles != [] ->
            ids = Enum.map_join(profiles, ", ", & &1.id)
            IO.puts(:stderr, "available profiles: #{ids}")

          _ ->
            IO.puts(:stderr, "run `tet profiles` to see available profiles")
        end

        66

      {:error, reason} ->
        IO.puts(:stderr, "tet profile #{command} failed: #{Render.error(reason)}")
        1
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

      {:error, :session_not_found} ->
        IO.puts(:stderr, "tet session show failed: session '#{session_id}' not found")
        IO.puts(:stderr, "run `tet sessions` to see available sessions")
        66

      {:error, reason} ->
        IO.puts(:stderr, "tet session show failed: #{Render.error(reason)}")
        1
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

  defp completion([shell]) do
    case Completion.generate(shell) do
      {:ok, script} ->
        IO.puts(script)
        0

      {:error, reason} ->
        IO.puts(:stderr, "tet completion failed: #{Render.error(reason)}")
        1
    end
  end

  defp completion(_args) do
    IO.puts(:stderr, "usage: tet completion <bash|zsh|fish>")
    64
  end

  defp history(["search" | rest]) do
    case parse_history_search(rest) do
      {:ok, {query, opts}} ->
        if query == "" do
          IO.puts(:stderr, "usage: tet history search [--fuzzy] [--limit N] QUERY")
          64
        else
          case History.search(query, opts) do
            {:ok, entries} ->
              IO.puts(History.render(entries))
              0

            {:error, reason} ->
              IO.puts(:stderr, "tet history search failed: #{Render.error(reason)}")
              1
          end
        end

      {:error, message} ->
        IO.puts(:stderr, message)
        64
    end
  end

  defp history(_args) do
    IO.puts(:stderr, "usage: tet history search [--fuzzy] [--limit N] QUERY")
    64
  end

  defp parse_history_search(args) do
    parse_history_search(args, [], [])
  end

  defp parse_history_search([], opts, query_parts) do
    {:ok, {query_parts |> Enum.reverse() |> Enum.join(" ") |> String.trim(), opts}}
  end

  defp parse_history_search(["--fuzzy" | rest], opts, query_parts) do
    parse_history_search(rest, [{:mode, :fuzzy} | opts], query_parts)
  end

  defp parse_history_search(["--limit", limit | rest], opts, query_parts) do
    case Integer.parse(limit) do
      {n, ""} when n > 0 ->
        parse_history_search(rest, [{:limit, n} | opts], query_parts)

      _ ->
        {:error, "invalid --limit value: #{inspect(limit)}"}
    end
  end

  defp parse_history_search(["--limit" | _rest], _opts, _query_parts) do
    {:error, "--limit requires a positive integer"}
  end

  defp parse_history_search([part | rest], opts, query_parts) do
    parse_history_search(rest, opts, [part | query_parts])
  end

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

  # ── Prompt Lab commands ──────────────────────────────────────────────────

  defp prompt_lab([]) do
    IO.puts(:stderr, "usage: tet prompt-lab (refine | presets | dimensions)")
    64
  end

  defp prompt_lab(["refine" | args]) do
    case extract_prompt_lab_opts(args, []) do
      {:ok, opts, prompt_parts} ->
        prompt = Enum.join(prompt_parts, " ") |> String.trim()

        if prompt == "" do
          IO.puts(:stderr, "usage: tet prompt-lab refine [--preset PRESET] [--json] PROMPT")
          64
        else
          preset_id = Keyword.get(opts, :preset_id, "general")
          json_mode? = Keyword.get(opts, :json, false)

          case Tet.PromptLab.refine(prompt, preset: preset_id) do
            {:ok, refinement} ->
              output =
                if json_mode? do
                  Render.prompt_lab_refinement_json(refinement)
                else
                  Render.prompt_lab_refinement(refinement)
                end

              IO.puts(output)
              0

            {:error, reason} ->
              IO.puts(:stderr, "prompt-lab refine failed: #{Render.error(reason)}")
              1
          end
        end

      {:error, message} ->
        IO.puts(:stderr, message)
        IO.puts(:stderr, "usage: tet prompt-lab refine [--preset PRESET] [--json] PROMPT")
        64
    end
  end

  defp prompt_lab(["presets" | args]) do
    json_mode? = "--json" in args
    presets = Tet.PromptLab.presets()

    output =
      if json_mode? do
        Render.prompt_lab_presets_json(presets)
      else
        Render.prompt_lab_presets(presets)
      end

    IO.puts(output)
    0
  end

  defp prompt_lab(["dimensions" | args]) do
    json_mode? = "--json" in args
    dimensions = Tet.PromptLab.quality_dimensions()

    output =
      if json_mode? do
        Render.prompt_lab_dimensions_json(dimensions)
      else
        Render.prompt_lab_dimensions(dimensions)
      end

    IO.puts(output)
    0
  end

  defp prompt_lab(_args) do
    IO.puts(:stderr, "usage: tet prompt-lab (refine | presets | dimensions)")
    64
  end

  defp extract_prompt_lab_opts(["--preset", preset_id | rest], opts) do
    extract_prompt_lab_opts(rest, [{:preset_id, preset_id} | opts])
  end

  defp extract_prompt_lab_opts(["--preset"], _opts) do
    {:error, "--preset requires a preset id"}
  end

  defp extract_prompt_lab_opts(["--preset" <> _invalid], _opts) do
    {:error, "--preset requires a preset id"}
  end

  defp extract_prompt_lab_opts(["--json" | rest], opts) do
    extract_prompt_lab_opts(rest, [{:json, true} | opts])
  end

  defp extract_prompt_lab_opts(prompt_parts, opts) when is_list(prompt_parts) do
    {:ok, Enum.reverse(opts), prompt_parts}
  end

  # ── Command correction commands ───────────────────────────────────────────

  defp correct([]) do
    IO.puts(:stderr, "usage: tet correct [--json] COMMAND")
    64
  end

  defp correct(args) do
    json_mode? = "--json" in args
    parts = Enum.reject(args, &(&1 == "--json"))
    command = Enum.join(parts, " ") |> String.trim()

    if command == "" do
      IO.puts(:stderr, "usage: tet correct [--json] COMMAND")
      64
    else
      suggestions = Tet.Command.Correction.suggest(command, %{})

      output =
        if json_mode? do
          Render.command_suggestions_json(suggestions)
        else
          Render.command_suggestions(suggestions)
        end

      IO.puts(output)
      0
    end
  end
end
