defmodule Tet.Runtime.ProviderConfig do
  @moduledoc """
  Runtime-owned provider selection and validation.

  Secrets are read from environment variables or explicit runtime opts. Nothing
  in application config contains an API key.
  """

  @default_openai_base_url "https://api.openai.com/v1"
  @default_openai_model "gpt-4o-mini"

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

      unknown ->
        {:error, {:unknown_provider, unknown}}
    end
  end

  @doc "Returns the selected provider name after env/config/opts normalization."
  def provider_name(opts \\ []) when is_list(opts) do
    opts
    |> Keyword.get(:provider)
    |> blank_fallback(System.get_env("TET_PROVIDER"))
    |> blank_fallback(Application.get_env(:tet_runtime, :provider, :mock))
    |> normalize_provider()
  end

  defp resolve_openai_compatible(opts) do
    app_config = Application.get_env(:tet_runtime, :openai_compatible, [])

    api_key_env =
      Keyword.get(opts, :api_key_env, Keyword.get(app_config, :api_key_env, "TET_OPENAI_API_KEY"))

    api_key = Keyword.get(opts, :api_key) || env(api_key_env)

    if blank?(api_key) do
      {:error, {:missing_provider_env, api_key_env}}
    else
      {:ok,
       {Tet.Runtime.Provider.OpenAICompatible,
        [
          provider: :openai_compatible,
          api_key: api_key,
          base_url:
            value(opts, app_config, :base_url, "TET_OPENAI_BASE_URL", @default_openai_base_url),
          model: value(opts, app_config, :model, "TET_OPENAI_MODEL", @default_openai_model),
          timeout: Keyword.get(opts, :timeout, Keyword.get(app_config, :timeout, 60_000))
        ]}}
    end
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
      other -> {:unknown, other}
    end
  end

  defp normalize_provider(_), do: :mock

  defp blank_fallback(value, fallback) do
    if blank?(value), do: fallback, else: value
  end

  defp blank?(value), do: is_nil(value) or value == ""
end
