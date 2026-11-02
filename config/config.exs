import Config

# Clementine's own development and tests. A host app configures
# :clementine itself; docs/MODELS.md has the models and their keys.
config :clementine,
  anthropic_api_key: {:system, "ANTHROPIC_API_KEY"},
  openai_api_key: {:system, "OPENAI_API_KEY"},
  retry: [
    max_attempts: 3,
    base_delay: 1000,
    max_delay: 30_000
  ]

import_config "#{config_env()}.exs"
