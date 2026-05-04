import Config

# Silence Ecto debug logs in production releases.
# In test/dev, compile-time config.exs defaults apply (no override).
if config_env() == :prod do
  config :logger, level: :warning
end
