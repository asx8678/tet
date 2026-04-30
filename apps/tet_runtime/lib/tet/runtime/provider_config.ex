defmodule Tet.Runtime.ProviderConfig do
  @moduledoc """
  Runtime-owned provider selection and validation.

  Secrets are read from environment variables or explicit runtime opts. Nothing
  in application config contains an API key.
  """

  alias Tet.Runtime.Provider.Error
  alias Tet.Runtime.Provider.Router.Candidates

  @default_openai_base_url "https://api.openai.com/v1"
  @default_openai_model "gpt-4o-mini"
  @default_router_profile "chat"

  @doc "Resolves the configured provider adapter and its validated options."
  def resolve(opts \\ []) when is_list(opts) do
    provider = provider_name(opts)

    case provider do
      :mock ->
        {:ok,
         {Tet.Runtime.Provider.Mock,
          [
            provider: :mock,
            response: Keyword.get(opts, :mock_response),
            chunks: Keyword.get(opts, :mock_chunks)
          ]}}

      :openai_compatible ->
        resolve_openai_compatible(opts)

      :router ->
        resolve_router(opts)

      unknown ->
        {:error, {:unknown_provider, unknown}}
    end
  end

  @doc "Returns a sanitized provider configuration diagnostic without network calls."
  def diagnose(opts \\ []) when is_list(opts) do
    case provider_name(opts) do
      :mock ->
        {:ok,
         %{
           provider: :mock,
           adapter: Tet.Runtime.Provider.Mock,
           status: :ok,
           message: "mock provider selected"
         }}

      :openai_compatible ->
        settings = openai_settings(opts)

        if blank?(settings.api_key) do
          {:error,
           %{
             provider: :openai_compatible,
             adapter: Tet.Runtime.Provider.OpenAICompatible,
             status: :error,
             reason: {:missing_provider_env, settings.api_key_env},
             required_env: settings.api_key_env,
             base_url: settings.base_url,
             model: settings.model,
             message:
               "OpenAI-compatible provider is missing required environment variable #{settings.api_key_env}"
           }}
        else
          {:ok,
           %{
             provider: :openai_compatible,
             adapter: Tet.Runtime.Provider.OpenAICompatible,
             status: :ok,
             required_env: settings.api_key_env,
             api_key_present?: true,
             base_url: settings.base_url,
             model: settings.model,
             timeout: settings.timeout,
             message: "OpenAI-compatible provider configured"
           }}
        end

      :router ->
        diagnose_router(opts)

      unknown ->
        {:error,
         %{
           provider: unknown,
           adapter: nil,
           status: :error,
           reason: {:unknown_provider, unknown},
           message: "unknown provider #{inspect(unknown)}"
         }}
    end
  end

  @doc "Returns the selected provider name after env/config/opts normalization."
  def provider_name(opts \\ []) when is_list(opts) do
    provider = Keyword.get(opts, :provider)

    if blank?(provider) and truthy?(Keyword.get(opts, :router)) do
      :router
    else
      provider
      |> blank_fallback(System.get_env("TET_PROVIDER"))
      |> blank_fallback(Application.get_env(:tet_runtime, :provider, :mock))
      |> normalize_provider()
    end
  end

  defp resolve_router(opts) do
    with {:ok, candidates} <- router_candidates(opts),
         {:ok, candidates} <- Candidates.normalize(candidates) do
      {:ok,
       {Tet.Runtime.Provider.Router,
        opts
        |> Keyword.take([
          :max_retries,
          :profile,
          :retries,
          :retry_delay_ms,
          :routing_key,
          :telemetry_emit
        ])
        |> Keyword.put(:candidates, candidates)}}
    end
  end

  defp resolve_openai_compatible(opts) do
    settings = openai_settings(opts)

    if blank?(settings.api_key) do
      {:error, {:missing_provider_env, settings.api_key_env}}
    else
      {:ok,
       {Tet.Runtime.Provider.OpenAICompatible,
        [
          provider: :openai_compatible,
          api_key: settings.api_key,
          base_url: settings.base_url,
          model: settings.model,
          timeout: settings.timeout
        ]}}
    end
  end

  defp router_candidates(opts) do
    case Keyword.fetch(opts, :candidates) do
      {:ok, candidates} when is_list(candidates) -> {:ok, candidates}
      {:ok, _candidates} -> {:error, {:invalid_router_candidates, :not_a_list}}
      :error -> registry_router_candidates(opts)
    end
  end

  defp registry_router_candidates(opts) do
    profile = router_profile(opts)

    with {:ok, registry} <- Tet.Runtime.ModelRegistry.load(opts),
         {:ok, pin} <- fetch_profile_pin(registry, profile) do
      candidates =
        [pin.default_model | pin.fallback_models]
        |> Enum.map(&registry_candidate(registry, &1, opts))

      {:ok, candidates}
    else
      :error -> {:error, {:unknown_profile, profile}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_profile_pin(registry, profile) do
    case Tet.ModelRegistry.profile_pin(registry, profile) do
      {:ok, pin} -> {:ok, pin}
      :error -> :error
    end
  end

  defp registry_candidate(registry, model_id, opts) do
    with {:ok, model} <- Tet.ModelRegistry.model(registry, model_id),
         {:ok, provider} <- Tet.ModelRegistry.provider(registry, model.provider) do
      candidate_for_provider(model, provider, opts)
    else
      :error ->
        %{
          id: model_id,
          provider: nil,
          adapter: nil,
          config_error: {:unknown_model, model_id},
          opts: []
        }
    end
  end

  defp candidate_for_provider(model, provider, opts) do
    case normalize_provider(provider.type) do
      :mock -> mock_candidate(model, opts)
      :openai_compatible -> openai_candidate(model, provider.config, opts)
      unknown -> unknown_provider_candidate(model, provider, unknown)
    end
  end

  defp mock_candidate(model, opts) do
    provider_opts =
      [provider: :mock, model: model.model]
      |> put_optional(:response, Keyword.get(opts, :mock_response))
      |> put_optional(:chunks, Keyword.get(opts, :mock_chunks))
      |> put_optional(:usage, Keyword.get(opts, :usage))

    %{
      id: model.id,
      provider: :mock,
      adapter: Tet.Runtime.Provider.Mock,
      model: model.model,
      opts: provider_opts
    }
  end

  defp openai_candidate(model, provider_config, opts) do
    settings = openai_candidate_settings(model, provider_config, opts)

    provider_opts =
      [
        provider: :openai_compatible,
        base_url: settings.base_url,
        model: settings.model,
        timeout: settings.timeout
      ]
      |> put_optional(:api_key, settings.api_key)

    %{
      id: model.id,
      provider: :openai_compatible,
      adapter: Tet.Runtime.Provider.OpenAICompatible,
      model: settings.model,
      opts: provider_opts,
      config_error: missing_api_key_error(settings)
    }
  end

  defp unknown_provider_candidate(model, provider, unknown) do
    %{
      id: model.id,
      provider: provider.type,
      adapter: nil,
      model: model.model,
      opts: [],
      config_error: {:unknown_provider, unknown}
    }
  end

  defp openai_candidate_settings(model, provider_config, opts) do
    app_config = Application.get_env(:tet_runtime, :openai_compatible, [])

    api_key_env =
      opts
      |> Keyword.get(:api_key_env)
      |> blank_fallback(config_value(provider_config, :api_key_env))
      |> blank_fallback(Keyword.get(app_config, :api_key_env))
      |> blank_fallback("TET_OPENAI_API_KEY")

    model_env = config_value(provider_config, :model_env) || "TET_OPENAI_MODEL"

    %{
      api_key_env: api_key_env,
      api_key: Keyword.get(opts, :api_key) || env(api_key_env),
      base_url:
        Keyword.get(opts, :base_url) || env("TET_OPENAI_BASE_URL") ||
          config_value(provider_config, :base_url) || Keyword.get(app_config, :base_url) ||
          @default_openai_base_url,
      model: env(model_env) || model.model,
      timeout: Keyword.get(opts, :timeout, Keyword.get(app_config, :timeout, 60_000))
    }
  end

  defp missing_api_key_error(%{api_key: api_key, api_key_env: api_key_env}) do
    if blank?(api_key), do: {:missing_provider_env, api_key_env}, else: nil
  end

  defp diagnose_router(opts) do
    with {:ok, candidates} <- router_candidates(opts),
         {:ok, candidates} <- Candidates.normalize(candidates) do
      router_diagnostic_report(candidates, opts)
    else
      {:error, reason} -> router_config_error_report(opts, reason)
    end
  end

  defp router_diagnostic_report(candidates, opts) do
    candidates = candidates |> Enum.with_index() |> Enum.map(&sanitize_router_candidate/1)
    config_errors = Enum.filter(candidates, &Map.get(&1, :config_error?, false))
    status = router_diagnostic_status(candidates, config_errors)
    reason = router_diagnostic_reason(status, config_errors)

    report =
      %{
        provider: :router,
        adapter: Tet.Runtime.Provider.Router,
        status: status,
        profile: router_profile(opts),
        candidate_count: length(candidates),
        viable_candidate_count: length(candidates) - length(config_errors),
        config_error_count: length(config_errors),
        candidates: candidates,
        config_errors: config_errors,
        reason: reason,
        detail: router_diagnostic_detail(status, reason),
        message: router_diagnostic_message(status)
      }
      |> compact_map()

    if status == :error, do: {:error, report}, else: {:ok, report}
  end

  defp router_config_error_report(opts, reason) do
    {:error,
     %{
       provider: :router,
       adapter: Tet.Runtime.Provider.Router,
       status: :error,
       profile: router_profile(opts),
       reason: Tet.Redactor.redact(reason),
       detail: Error.detail(reason),
       message: "provider router configuration failed"
     }}
  end

  defp router_diagnostic_status([], _config_errors), do: :error

  defp router_diagnostic_status(candidates, config_errors)
       when length(candidates) == length(config_errors),
       do: :error

  defp router_diagnostic_status(_candidates, []), do: :ok
  defp router_diagnostic_status(_candidates, _config_errors), do: :degraded

  defp router_diagnostic_reason(:ok, _config_errors), do: nil

  defp router_diagnostic_reason(:degraded, config_errors),
    do: {:candidate_config_errors, config_errors}

  defp router_diagnostic_reason(:error, []), do: :no_provider_candidates
  defp router_diagnostic_reason(:error, config_errors), do: {:no_viable_candidates, config_errors}

  defp router_diagnostic_detail(:error, reason),
    do: Error.detail({:provider_candidate_config, reason})

  defp router_diagnostic_detail(_status, _reason), do: nil

  defp router_diagnostic_message(:ok), do: "provider router configured"

  defp router_diagnostic_message(:degraded),
    do: "provider router configured with fallbackable candidate configuration errors"

  defp router_diagnostic_message(:error), do: "provider router has no viable candidates"

  defp sanitize_router_candidate({candidate, index}) do
    candidate = diagnostic_candidate(candidate)
    opts = candidate_value(candidate, :opts) || []
    opts = if is_list(opts), do: opts, else: []
    config_error = candidate_value(candidate, :config_error)

    %{
      candidate_index: index,
      id: candidate_value(candidate, :id),
      provider: candidate_value(candidate, :provider) || Keyword.get(opts, :provider),
      model: candidate_value(candidate, :model) || Keyword.get(opts, :model),
      config_error?: not is_nil(config_error),
      config_error_detail: config_error_detail(config_error)
    }
    |> compact_map()
  end

  defp diagnostic_candidate(candidate) when is_map(candidate), do: candidate
  defp diagnostic_candidate(_candidate), do: %{}

  defp config_error_detail(nil), do: nil
  defp config_error_detail(reason), do: Error.detail({:provider_candidate_config, reason})

  defp candidate_value(candidate, key) when is_map(candidate) do
    Map.get(candidate, key, Map.get(candidate, Atom.to_string(key)))
  end

  defp candidate_value(_candidate, _key), do: nil

  defp compact_map(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp router_profile(opts) do
    opts
    |> Keyword.get(:profile)
    |> blank_fallback(Keyword.get(opts, :router_profile))
    |> blank_fallback(System.get_env("TET_PROFILE"))
    |> blank_fallback(Application.get_env(:tet_runtime, :profile))
    |> blank_fallback(@default_router_profile)
    |> to_string()
  end

  defp config_value(config, key) when is_map(config) do
    Map.get(config, key, Map.get(config, Atom.to_string(key)))
  end

  defp config_value(_config, _key), do: nil

  defp put_optional(opts, _key, nil), do: opts
  defp put_optional(opts, key, value), do: Keyword.put(opts, key, value)

  defp openai_settings(opts) do
    app_config = Application.get_env(:tet_runtime, :openai_compatible, [])

    api_key_env =
      opts
      |> Keyword.get(:api_key_env)
      |> blank_fallback(Keyword.get(app_config, :api_key_env))
      |> blank_fallback("TET_OPENAI_API_KEY")

    %{
      api_key_env: api_key_env,
      api_key: Keyword.get(opts, :api_key) || env(api_key_env),
      base_url:
        value(opts, app_config, :base_url, "TET_OPENAI_BASE_URL", @default_openai_base_url),
      model: value(opts, app_config, :model, "TET_OPENAI_MODEL", @default_openai_model),
      timeout: Keyword.get(opts, :timeout, Keyword.get(app_config, :timeout, 60_000))
    }
  end

  defp value(opts, app_config, key, env_name, default) do
    Keyword.get(opts, key) || env(env_name) || Keyword.get(app_config, key) || default
  end

  defp env(name) when is_binary(name), do: System.get_env(name)

  defp normalize_provider(value) when is_atom(value), do: value

  defp normalize_provider(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> case do
      "mock" -> :mock
      "openai" -> :openai_compatible
      "openai_compatible" -> :openai_compatible
      "router" -> :router
      other -> {:unknown, other}
    end
  end

  defp normalize_provider(_), do: :mock

  defp blank_fallback(value, fallback) do
    if blank?(value), do: fallback, else: value
  end

  defp truthy?(value) when value in [true, "true", "1", "yes", "on"], do: true
  defp truthy?(_value), do: false

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(value), do: is_nil(value)
end
