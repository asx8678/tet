defmodule Tet.CLI.Render do
  @moduledoc false

  alias Tet.Prompt.Canonical

  def help do
    """
    tet - standalone Tet CLI scaffold

    Commands:
      tet ask [--session SESSION_ID] PROMPT  Stream a reply and persist the chat turn
      tet events [--session SESSION_ID]     Show the read-only runtime event timeline
      tet timeline [--session SESSION_ID]   Alias for `tet events`
      tet profiles                         List configured agent profiles
      tet profile show PROFILE_ID          Inspect one configured agent profile
      tet sessions                         List persisted sessions
      tet session show SESSION_ID          Show a session and its messages
      tet doctor                           Check config/store/provider/release health
      tet completion <bash|zsh|fish>        Generate shell completion scripts
      tet history search [--fuzzy] [--limit N] QUERY  Search prompt history (default: substring; --fuzzy: fuzzy)
      tet prompt-lab refine PROMPT         Refine a prompt (--preset, --json)
      tet prompt-lab presets               List available prompt presets (--json)
      tet prompt-lab dimensions            List quality dimensions (--json)
      tet correct COMMAND                  Suggest safer command alternatives (--json)
      tet help                             Show this help
    """
  end

  def stream_event(%Tet.Event{type: :provider_text_delta, payload: payload}) do
    Map.get(payload, :text) || Map.get(payload, "text") || ""
  end

  def stream_event(%Tet.Event{type: :assistant_chunk, metadata: metadata} = event) do
    if normalized_text_compat?(metadata) do
      nil
    else
      assistant_chunk_content(event)
    end
  end

  def stream_event(_event), do: nil

  def events([]), do: "No events found."

  def events(events) when is_list(events) do
    events
    |> Enum.map(&event_line/1)
    |> then(&Enum.join(["Events:" | &1], "\n"))
  end

  def error(:empty_prompt), do: "prompt cannot be empty"
  def error(:invalid_session_id), do: "session id is invalid"
  def error(:empty_session_id), do: "session id cannot be empty"
  def error(:session_not_found), do: "session not found"
  def error(:autosave_not_found), do: "autosave checkpoint not found"
  def error(:profile_not_found), do: "profile not found"
  def error(:store_not_configured), do: "store is not configured"

  def error({:missing_provider_env, env_name}) do
    "provider is missing required environment variable #{env_name}"
  end

  def error({:unknown_provider, provider}) do
    "unknown provider #{inspect(provider)}"
  end

  def error({:store_adapter_unavailable, adapter}) do
    "store adapter unavailable: #{inspect(adapter)}"
  end

  def error({:store_adapter_missing_callbacks, adapter, callbacks}) do
    "store adapter #{inspect(adapter)} is missing callbacks: #{Enum.join(callbacks, ", ")}"
  end

  def error({:store_unhealthy, path, reason}) do
    "store path #{path} is unhealthy: #{inspect(reason)}"
  end

  def error({:provider_http_error, reason}) do
    "provider HTTP error: #{inspect(reason)}"
  end

  def error({:provider_http_status, status, reason_phrase, body}) do
    "provider HTTP #{status} #{reason_phrase}: #{body}"
  end

  def error(%Tet.ProfileRegistry.Error{} = error), do: Tet.ProfileRegistry.format_error(error)
  def error(%Tet.ModelRegistry.Error{} = error), do: Tet.ModelRegistry.format_error(error)

  def error(errors) when is_list(errors) do
    if errors != [] and Enum.all?(errors, &registry_error?/1) do
      Enum.map_join(errors, "; ", &format_registry_error/1)
    else
      inspect(errors)
    end
  end

  def error(:provider_timeout), do: "provider timed out"
  def error(reason), do: inspect(reason)

  def profiles([]), do: "No profiles found."

  def profiles(profiles) when is_list(profiles) do
    profiles
    |> Enum.map(&profile_summary_line/1)
    |> then(&Enum.join(["Profiles:" | &1], "\n"))
  end

  def profile_show(profile) when is_map(profile) do
    model = profile.overlays.model
    fallbacks = model.fallback_models |> Enum.join(", ") |> blank_label()
    tags = profile.tags |> Enum.join(", ") |> blank_label()

    [
      "Profile #{profile.id}",
      "display_name: #{profile.display_name}",
      "description: #{profile.description}",
      "version: #{profile.version}",
      "tags: #{tags}",
      "model: default=#{Map.get(model, :default_model, "n/a")} fallbacks=#{fallbacks}",
      "overlays:" | overlay_lines(profile.overlays)
    ]
    |> Enum.join("\n")
  end

  def sessions([]), do: "No sessions found."

  def sessions(sessions) when is_list(sessions) do
    sessions
    |> Enum.map(&session_summary_line/1)
    |> then(&Enum.join(["Sessions:" | &1], "\n"))
  end

  def session_show(%{session: session, messages: messages}) do
    message_lines = Enum.map(messages, &message_line/1)

    [
      "Session #{session.id}",
      "messages: #{session.message_count}",
      "started_at: #{session.started_at || "n/a"}",
      "updated_at: #{session.updated_at || "n/a"}",
      "Messages:" | message_lines
    ]
    |> Enum.join("\n")
  end

  def doctor(%{profile: profile, applications: applications, store: store} = report) do
    status = Map.get(report, :status, :ok)
    application_list = applications |> Enum.map(&Atom.to_string/1) |> Enum.join(", ")
    provider = Map.get(report, :provider, %{})
    release_boundary = Map.get(report, :release_boundary, %{})
    check_lines = report |> Map.get(:checks, []) |> Enum.map(&doctor_check_line/1)

    [
      "Tet standalone doctor: #{status}",
      "profile: #{profile}",
      "applications: #{application_list}",
      "store: #{inspect(Map.get(store, :adapter))} (#{Map.get(store, :status, :unknown)})",
      "store_path: #{Map.get(store, :path, "n/a")}",
      "provider: #{inspect(Map.get(provider, :provider, :unknown))} (#{Map.get(provider, :status, :unknown)})",
      "release_boundary: #{Map.get(release_boundary, :status, :unknown)}",
      "checks:" | check_lines
    ]
    |> Enum.join("\n")
  end

  # ── Prompt Lab rendering ────────────────────────────────────────────────

  @doc "Formats a single refinement as human-readable output."
  def prompt_lab_refinement(refinement) do
    quality_lines = quality_score_lines(refinement.scores_before, refinement.scores_after)

    [
      "Prompt refinement #{refinement.status}",
      "  preset: #{refinement.preset_id}",
      "  summary: #{refinement.summary}",
      quality_lines,
      prompt_lab_change_summary(refinement.changes),
      prompt_lab_questions(refinement.questions),
      prompt_lab_warnings(refinement.warnings),
      "  refined prompt:",
      indent_block(refinement.refined_prompt, 4)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  @doc "Formats a refinement as JSON for scriptable consumption."
  def prompt_lab_refinement_json(refinement) do
    map = Tet.PromptLab.Refinement.to_map(refinement)
    json = Canonical.encode(map)
    json <> "\n"
  end

  @doc "Formats presets as human-readable list."
  def prompt_lab_presets(presets) when is_list(presets) do
    lines =
      Enum.map(presets, fn preset ->
        tags = Enum.join(preset.tags, ", ")

        "  #{preset.id}: #{preset.name} (#{Enum.count(preset.dimensions)} dimensions, tags: #{tags})"
      end)

    ["Prompt Lab presets:" | lines]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  @doc "Formats presets as JSON."
  def prompt_lab_presets_json(presets) when is_list(presets) do
    maps = Enum.map(presets, &Tet.PromptLab.Preset.to_map/1)
    json = Canonical.encode(maps)
    json <> "\n"
  end

  @doc "Formats dimensions as human-readable list."
  def prompt_lab_dimensions(dimensions) when is_list(dimensions) do
    lines =
      Enum.map(dimensions, fn dim ->
        "  #{dim.id}: #{dim.label}\n    #{dim.description}\n    rubric: #{dim.rubric}"
      end)

    ["Prompt Lab quality dimensions:" | lines]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  @doc "Formats dimensions as JSON."
  def prompt_lab_dimensions_json(dimensions) when is_list(dimensions) do
    maps = Enum.map(dimensions, &Tet.PromptLab.Dimension.to_map/1)
    json = Canonical.encode(maps)
    json <> "\n"
  end

  # ── Command correction rendering ────────────────────────────────────────

  @doc "Formats command suggestions as human-readable output with 'Did you mean' hints."
  def command_suggestions(suggestions) when is_list(suggestions) do
    lines =
      suggestions
      |> Enum.with_index()
      |> Enum.flat_map(fn {suggestion, idx} ->
        [
          "  #{idx + 1}. #{label_for_suggestion_type(suggestion)}",
          "     #{command_suggestion_detail(suggestion)}"
        ]
      end)

    ["Command corrections:" | lines]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  @doc "Formats command suggestions as JSON."
  def command_suggestions_json(suggestions) when is_list(suggestions) do
    maps = Enum.map(suggestions, &Tet.Command.Suggestion.to_map/1)
    json = Canonical.encode(maps)
    json <> "\n"
  end

  # ── Prompt Lab helpers ──────────────────────────────────────────────────

  defp quality_score_lines(before_scores, after_scores) do
    before_scores
    |> Enum.sort_by(fn {dim_id, _entry} -> dim_id end)
    |> Enum.map(fn {dim_id, before_entry} ->
      after_entry = Map.fetch!(after_scores, dim_id)
      before_score = before_entry["score"]
      after_score = after_entry["score"]
      label = String.replace(dim_id, "_", " ")
      arrow = score_arrow(before_score, after_score)
      "    #{label}: #{before_score} #{arrow} #{after_score}/10 (#{after_entry["comment"]})"
    end)
  end

  defp score_arrow(b_val, a_val) when a_val > b_val, do: "→"
  defp score_arrow(b_val, a_val) when a_val < b_val, do: "←"
  defp score_arrow(_b_val, _a_val), do: "="

  defp label_for_suggestion_type(%{correction_type: :safe}), do: "✅ Safe — proceeding as-is"
  defp label_for_suggestion_type(%{correction_type: :modified}), do: "✏️  Did you mean:"

  defp label_for_suggestion_type(%{correction_type: :blocked}),
    do: "🚫 Blocked — no safe alternative"

  defp command_suggestion_detail(%{suggested_command: nil, reason: reason} = suggestion) do
    "#{reason} | risk: #{risk_label_with_icon(suggestion)}"
  end

  defp command_suggestion_detail(%{suggested_command: cmd, reason: reason} = suggestion) do
    "#{cmd} — #{reason} | risk: #{risk_label_with_icon(suggestion)}"
  end

  defp risk_label_with_icon(%{risk_level: :none}), do: "No risk (read-only)"
  defp risk_label_with_icon(%{risk_level: :low}), do: "Low risk (minimally invasive)"
  defp risk_label_with_icon(%{risk_level: :medium}), do: "Medium risk (potentially destructive)"
  defp risk_label_with_icon(%{risk_level: :high}), do: "High risk (destructive operation)"
  defp risk_label_with_icon(%{risk_level: :critical}), do: "Critical risk (system-destructive)"

  defp prompt_lab_change_summary([]), do: nil

  defp prompt_lab_change_summary(changes) do
    lines =
      Enum.map(changes, fn change ->
        "    #{change["dimension"]}: #{change["kind"]} (#{change["impact"]}) — #{change["rationale"]}"
      end)

    ["  changes:" | lines]
    |> Enum.join("\n")
  end

  defp prompt_lab_questions([]), do: nil

  defp prompt_lab_questions(questions) do
    lines = Enum.map(questions, &"    ? #{&1}")

    ["  clarifying questions:" | lines]
    |> Enum.join("\n")
  end

  defp prompt_lab_warnings([]), do: nil

  defp prompt_lab_warnings(warnings) do
    lines = Enum.map(warnings, &"    ⚠ #{&1}")

    ["  warnings:" | lines]
    |> Enum.join("\n")
  end

  defp indent_block(text, spaces) do
    indent = String.duplicate(" ", spaces)
    replaced = String.replace(text, "\n", "\n#{indent}")
    "#{indent}#{replaced}"
  end

  defp registry_error?(%Tet.ProfileRegistry.Error{}), do: true
  defp registry_error?(%Tet.ModelRegistry.Error{}), do: true
  defp registry_error?(_error), do: false

  defp format_registry_error(%Tet.ProfileRegistry.Error{} = error),
    do: Tet.ProfileRegistry.format_error(error)

  defp format_registry_error(%Tet.ModelRegistry.Error{} = error),
    do: Tet.ModelRegistry.format_error(error)

  defp event_line(%Tet.Event{} = event) do
    [
      "  ##{event.sequence || "-"}",
      event_timestamp(event),
      "session=#{event.session_id || "n/a"}",
      Atom.to_string(event.type),
      event_details(event)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp event_timestamp(event) do
    payload_value(event.metadata, :timestamp) || "n/a"
  end

  defp event_details(%Tet.Event{type: :message_persisted, payload: payload}) do
    [
      maybe_detail("role", payload_value(payload, :role)),
      maybe_detail("message_id", payload_value(payload, :message_id))
    ]
    |> compact_details()
  end

  defp event_details(%Tet.Event{type: :assistant_chunk, payload: payload}) do
    [
      maybe_detail("content", payload_value(payload, :content), quoted?: true),
      maybe_detail("provider", payload_value(payload, :provider))
    ]
    |> compact_details()
  end

  defp event_details(%Tet.Event{type: :provider_text_delta, payload: payload}) do
    [
      maybe_detail("text", payload_value(payload, :text), quoted?: true),
      maybe_detail("provider", payload_value(payload, :provider)),
      maybe_detail("model", payload_value(payload, :model))
    ]
    |> compact_details()
  end

  defp event_details(%Tet.Event{type: :provider_error, payload: payload}) do
    [
      maybe_detail("kind", payload_value(payload, :kind)),
      maybe_detail("retryable", payload_value(payload, :retryable?)),
      maybe_detail("detail", payload_value(payload, :detail), quoted?: true)
    ]
    |> compact_details()
  end

  defp event_details(%Tet.Event{payload: payload}) when map_size(payload) == 0, do: ""

  defp event_details(%Tet.Event{payload: payload}) do
    payload
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, value} -> maybe_detail(to_string(key), value) end)
    |> compact_details()
  end

  defp normalized_text_compat?(metadata) do
    payload_value(metadata, :normalized_type) in [:provider_text_delta, "provider_text_delta"]
  end

  defp assistant_chunk_content(%Tet.Event{payload: payload}) do
    Map.get(payload, :content) || Map.get(payload, "content") || ""
  end

  defp maybe_detail(key, value, opts \\ [])
  defp maybe_detail(_key, nil, _opts), do: nil

  defp maybe_detail(key, value, opts) do
    formatted =
      if Keyword.get(opts, :quoted?, false) do
        value |> format_quoted_value() |> inspect()
      else
        format_value(value)
      end

    "#{key}=#{formatted}"
  end

  defp compact_details(details) do
    details
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp payload_value(payload, key) do
    Map.get(payload, key, Map.get(payload, Atom.to_string(key)))
  end

  defp format_quoted_value(value) when is_binary(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 80)
  end

  defp format_quoted_value(value), do: format_value(value)

  defp format_value(value) when is_binary(value), do: preview(value)
  defp format_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_value(value) when is_boolean(value), do: to_string(value)
  defp format_value(value) when is_integer(value), do: Integer.to_string(value)
  defp format_value(value), do: inspect(value)

  defp profile_summary_line(profile) do
    tags = profile.tags |> Enum.join(",") |> blank_label()
    overlays = profile.overlay_kinds |> Enum.map(&Atom.to_string/1) |> Enum.join(",")
    model = profile.default_model || "n/a"

    "  #{profile.id}  model=#{model} version=#{profile.version} tags=#{tags} overlays=#{overlays}"
  end

  defp overlay_lines(overlays) do
    Tet.ProfileRegistry.overlay_kinds()
    |> Enum.map(fn kind ->
      value = Map.fetch!(overlays, kind)
      "  #{kind}: #{inspect(value, pretty: true, limit: :infinity)}"
    end)
  end

  defp session_summary_line(session) do
    last =
      case {session.last_role, session.last_content} do
        {nil, _content} -> "n/a"
        {role, nil} -> Atom.to_string(role)
        {role, content} -> "#{role}: #{preview(content)}"
      end

    "  #{session.id}  messages=#{session.message_count} updated=#{session.updated_at || "n/a"} last=#{last}"
  end

  defp message_line(message) do
    "  [#{message.role}] #{indent_multiline(message.content)}"
  end

  defp doctor_check_line(%{name: name, status: status, message: message}) do
    "  [#{status}] #{name} - #{message}"
  end

  defp preview(content) do
    content
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 80)
  end

  defp blank_label(""), do: "n/a"
  defp blank_label(value), do: value

  defp indent_multiline(content) do
    String.replace(content, "\n", "\n    ")
  end
end
