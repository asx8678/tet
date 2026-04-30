defmodule Tet.Runtime.PromptLab do
  @moduledoc """
  Runtime Prompt Lab facade/orchestration.

  This module deliberately does not call chat providers, runtime tools, message
  persistence, autosave, or timeline events. Its only allowed write is the
  dedicated Prompt Lab history store, and callers can disable that with
  `persist?: false`. Read-only prompt polishing: revolutionary, apparently.
  """

  alias Tet.PromptLab.HistoryEntry
  alias Tet.Runtime.{Ids, StoreConfig}

  @doc "Returns Prompt Lab boundary metadata for docs, tests, and future dashboards."
  def boundary do
    Tet.PromptLab.boundary()
    |> Map.merge(%{
      application: :tet_runtime,
      side_effects: true,
      allowed_store_writes: [:prompt_history],
      forbidden_store_writes: [:messages, :autosaves, :events],
      calls_providers: false,
      executes_tools: false
    })
  end

  @doc "Lists built-in Prompt Lab presets."
  def list_presets do
    {:ok, Tet.PromptLab.presets()}
  end

  @doc "Fetches one built-in Prompt Lab preset."
  def get_preset(preset_id) do
    Tet.PromptLab.get_preset(preset_id)
  end

  @doc "Refines a prompt and optionally appends a Prompt Lab history entry."
  def refine(prompt, opts \\ []) when is_binary(prompt) and is_list(opts) do
    with {:ok, refinement} <- Tet.PromptLab.refine(prompt, opts) do
      maybe_persist(refinement, prompt, opts)
    end
  end

  @doc "Lists Prompt Lab history entries, newest first."
  def list_history(opts \\ []) when is_list(opts) do
    with {:ok, adapter, store_opts} <- StoreConfig.resolve(opts, [:list_prompt_history]) do
      adapter.list_prompt_history(store_opts)
    end
  end

  @doc "Fetches one Prompt Lab history entry by id."
  def fetch_history(history_id, opts \\ []) when is_binary(history_id) and is_list(opts) do
    history_id = String.trim(history_id)

    with :ok <- validate_history_id(history_id),
         {:ok, adapter, store_opts} <- StoreConfig.resolve(opts, [:fetch_prompt_history]) do
      adapter.fetch_prompt_history(history_id, store_opts)
    end
  end

  defp maybe_persist(refinement, prompt, opts) do
    if Keyword.get(opts, :persist?, true) do
      persist(refinement, prompt, opts)
    else
      {:ok, %{refinement: refinement, history: nil}}
    end
  end

  defp persist(refinement, prompt, opts) do
    with {:ok, adapter, store_opts} <- StoreConfig.resolve(opts, [:save_prompt_history]),
         {:ok, history} <- build_history(refinement, prompt, opts),
         {:ok, history} <- adapter.save_prompt_history(history, store_opts) do
      {:ok, %{refinement: refinement, history: history}}
    end
  end

  defp build_history(refinement, prompt, opts) do
    preset_id = Keyword.get(opts, :preset_id, Keyword.get(opts, :preset, refinement.preset_id))

    with {:ok, request} <-
           Tet.PromptLab.Request.new(%{
             prompt: prompt,
             preset_id: preset_id,
             dimensions: Keyword.get(opts, :dimensions, []),
             metadata: Keyword.get(opts, :metadata, %{})
           }) do
      HistoryEntry.new(%{
        id: Keyword.get(opts, :history_id),
        created_at: Keyword.get(opts, :created_at, Ids.timestamp()),
        request: request,
        result: refinement,
        metadata: Keyword.get(opts, :history_metadata, %{})
      })
    end
  end

  defp validate_history_id(""), do: {:error, :empty_prompt_history_id}
  defp validate_history_id(_history_id), do: :ok
end
