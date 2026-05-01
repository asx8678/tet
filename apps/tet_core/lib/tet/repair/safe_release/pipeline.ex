defmodule Tet.Repair.SafeRelease.Pipeline do
  @moduledoc """
  Ordered repair pipeline definition for the safe repair release — BD-0063.

  Defines the canonical sequence of steps a repair release follows:

      diagnose → plan → approve → checkpoint → patch → compile → smoke → handoff

  Each step carries a configuration map describing its purpose, whether it
  is required, and its default timeout. Steps can be skipped only when
  marked as non-required (`:approve` and `:checkpoint`).

  This module is pure data and pure functions — no side effects.
  """

  @steps [
    :diagnose,
    :plan,
    :approve,
    :checkpoint,
    :patch,
    :compile,
    :smoke,
    :handoff
  ]

  @step_configs %{
    diagnose: %{
      description: "Identify the problem",
      required: true,
      timeout: 30_000
    },
    plan: %{
      description: "Create repair plan",
      required: true,
      timeout: 15_000
    },
    approve: %{
      description: "Get approval (auto-approved in emergency)",
      required: false,
      timeout: 60_000
    },
    checkpoint: %{
      description: "Take checkpoint before changes",
      required: false,
      timeout: 30_000
    },
    patch: %{
      description: "Apply patches",
      required: true,
      timeout: 60_000
    },
    compile: %{
      description: "Compile and verify",
      required: true,
      timeout: 120_000
    },
    smoke: %{
      description: "Run smoke tests",
      required: true,
      timeout: 120_000
    },
    handoff: %{
      description: "Transfer control back to main release",
      required: true,
      timeout: 30_000
    }
  }

  @skippable_steps [:approve, :checkpoint]

  @type step ::
          :diagnose | :plan | :approve | :checkpoint | :patch | :compile | :smoke | :handoff

  @type step_config :: %{
          description: String.t(),
          required: boolean(),
          timeout: pos_integer()
        }

  @doc "Returns the ordered list of all pipeline steps."
  @spec steps() :: [step()]
  def steps, do: @steps

  @doc """
  Returns configuration for a specific pipeline step.

  Returns `{:ok, config}` for known steps, `{:error, :unknown_step}` otherwise.
  """
  @spec step_config(step()) :: {:ok, step_config()} | {:error, :unknown_step}
  def step_config(step) when is_map_key(@step_configs, step) do
    {:ok, Map.fetch!(@step_configs, step)}
  end

  def step_config(_step), do: {:error, :unknown_step}

  @doc """
  Validates that a list of steps maintains the canonical pipeline order.

  Steps may be omitted (a valid subsequence is fine) but must not be
  reordered or duplicated.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate_step_order([step()]) :: :ok | {:error, term()}
  def validate_step_order(steps) when is_list(steps) do
    unknown = Enum.reject(steps, &(&1 in @steps))

    cond do
      unknown != [] ->
        {:error, {:unknown_steps, unknown}}

      not strictly_ordered?(steps) ->
        {:error, :invalid_step_order}

      true ->
        :ok
    end
  end

  @doc """
  Returns `true` if the given step can be safely skipped.

  Only `:approve` and `:checkpoint` are skippable.
  """
  @spec can_skip?(step()) :: boolean()
  def can_skip?(step), do: step in @skippable_steps

  # -- Private helpers --

  defp strictly_ordered?(ordered_steps) do
    ordered_steps
    |> Enum.map(fn step -> Enum.find_index(@steps, &(&1 == step)) end)
    |> strictly_increasing?()
  end

  defp strictly_increasing?([]), do: true
  defp strictly_increasing?([_]), do: true
  defp strictly_increasing?([a, b | rest]) when a < b, do: strictly_increasing?([b | rest])
  defp strictly_increasing?(_), do: false
end
