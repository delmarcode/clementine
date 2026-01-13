import Config

config :clementine,
  default_model: :claude_sonnet,
  api_key: {:system, "ANTHROPIC_API_KEY"},
  max_iterations: 10,
  timeout: :timer.minutes(5),
  retry: [
    max_attempts: 3,
    base_delay: 1000,
    max_delay: 30_000
  ]

config :clementine, :models,
  claude_sonnet: [
    provider: :anthropic,
    model: "claude-sonnet-4-20250514",
    max_tokens: 8192
  ],
  claude_haiku: [
    provider: :anthropic,
    model: "claude-haiku-4-5-20250514",
    max_tokens: 4096
  ],
  claude_opus: [
    provider: :anthropic,
    model: "claude-opus-4-20250514",
    max_tokens: 8192
  ]

import_config "#{config_env()}.exs"
