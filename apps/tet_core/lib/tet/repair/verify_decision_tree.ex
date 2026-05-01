defmodule Tet.Repair.VerifyDecisionTree do
  @moduledoc """
  Post-patch verification and reload strategy decision tree — BD-0061.

  After a repair patch is applied, this module determines whether the system
  should hot-reload the changed modules, perform a full restart, delegate to
  OTP's release handler, or flag for manual intervention.

  Decision flow:
  1. compile_check — did the patched code compile cleanly?
  2. smoke_test — do basic smoke tests pass?
  3. classify_modules — what kind of modules changed?
  4. hot_reload_safe? — are all changed modules safe to reload in place?

  If compilation fails → `:manual_intervention`
  If smoke tests fail → `:full_restart`
  If all modules safe → `:hot_reload`
  If has release config → `:release_handler`
  Otherwise → `:full_restart`

  This module is pure decision logic. No side effects.
  """

  alias Tet.Repair.VerifyDecisionTree.ModuleClassifier

  @type decision :: :hot_reload | :full_restart | :release_handler | :manual_intervention
  @type step_result :: :pass | :fail | :skip

  @type patch_result :: %{
          optional(:compile_status) => step_result(),
          optional(:smoke_status) => step_result(),
          optional(:changed_modules) => [atom() | String.t()],
          optional(:has_release_config) => boolean(),
          optional(atom()) => term()
        }

  @doc """
  Given a patch result map, returns the recommended reload strategy.

  The decision tree evaluates compile status, smoke test results, and
  module safety classification to determine the safest path forward.

  ## Examples

      iex> VerifyDecisionTree.decide(%{compile_status: :fail})
      {:ok, :manual_intervention}

      iex> VerifyDecisionTree.decide(%{
      ...>   compile_status: :pass,
      ...>   smoke_status: :pass,
      ...>   changed_modules: [MyApp.Helpers.StringUtils]
      ...> })
      {:ok, :hot_reload}
  """
  @spec decide(patch_result()) :: {:ok, decision()}
  def decide(patch_result) when is_map(patch_result) do
    decision =
      with :continue <- evaluate_compile(patch_result),
           :continue <- evaluate_smoke(patch_result),
           :continue <- evaluate_modules(patch_result) do
        # All checks passed but no modules to classify — safe default
        :full_restart
      end

    {:ok, decision}
  end

  @doc """
  Checks if the project compiles after patch application.

  Reads `:compile_status` from the patch result map.
  Returns `:pass` if compilation succeeded, `:fail` if it didn't,
  or `:skip` if no compile status was reported.

  ## Examples

      iex> VerifyDecisionTree.compile_check(%{compile_status: :pass})
      :pass
  """
  @spec compile_check(patch_result()) :: step_result()
  def compile_check(%{compile_status: status}) when status in [:pass, :fail, :skip], do: status
  def compile_check(_patch_result), do: :skip

  @doc """
  Checks if smoke tests pass after patch application.

  Reads `:smoke_status` from the patch result map.
  Returns `:pass` if tests passed, `:fail` if they didn't,
  or `:skip` if no smoke status was reported.

  ## Examples

      iex> VerifyDecisionTree.smoke_test(%{smoke_status: :pass})
      :pass
  """
  @spec smoke_test(patch_result()) :: step_result()
  def smoke_test(%{smoke_status: status}) when status in [:pass, :fail, :skip], do: status
  def smoke_test(_patch_result), do: :skip

  @doc """
  Classifies all changed modules in the patch result.

  Returns a list of `{module, classification}` tuples where classification
  is one of `:safe_reload`, `:unsafe_reload`, or `:unknown`.

  ## Examples

      iex> VerifyDecisionTree.classify_modules(%{changed_modules: [MyApp.Helpers.Foo]})
      [{MyApp.Helpers.Foo, :safe_reload}]
  """
  @spec classify_modules(patch_result()) :: [
          {atom() | String.t(), ModuleClassifier.classification()}
        ]
  def classify_modules(%{changed_modules: modules}) when is_list(modules) do
    Enum.map(modules, fn mod -> {mod, ModuleClassifier.classify(mod)} end)
  end

  def classify_modules(_patch_result), do: []

  @doc """
  Returns true if all changed modules are safe to hot-reload.

  A patch is safe for hot-reload only when every changed module is
  classified as `:safe_reload`. An empty module list is considered unsafe
  (we can't verify what we can't see).

  ## Examples

      iex> VerifyDecisionTree.hot_reload_safe?(%{changed_modules: [MyApp.Helpers.Foo]})
      true

      iex> VerifyDecisionTree.hot_reload_safe?(%{changed_modules: [MyApp.OrderServer]})
      false
  """
  @spec hot_reload_safe?(patch_result()) :: boolean()
  def hot_reload_safe?(%{changed_modules: modules}) when is_list(modules) and modules != [] do
    modules
    |> Enum.map(&ModuleClassifier.classify/1)
    |> Enum.all?(&(&1 == :safe_reload))
  end

  def hot_reload_safe?(_patch_result), do: false

  # -- Private decision steps --

  defp evaluate_compile(patch_result) do
    case compile_check(patch_result) do
      :fail -> :manual_intervention
      _other -> :continue
    end
  end

  defp evaluate_smoke(patch_result) do
    case smoke_test(patch_result) do
      :fail -> :full_restart
      _other -> :continue
    end
  end

  defp evaluate_modules(patch_result) do
    if hot_reload_safe?(patch_result) do
      choose_reload_strategy(patch_result)
    else
      :full_restart
    end
  end

  defp choose_reload_strategy(%{has_release_config: true}), do: :release_handler
  defp choose_reload_strategy(_patch_result), do: :hot_reload
end
