import Config

config :clementine,
  default_model: :claude_sonnet,
  anthropic_api_key: {:system, "ANTHROPIC_API_KEY"},
  openai_api_key: {:system, "OPENAI_API_KEY"},
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
    id: "claude-sonnet-5"
  ],
  claude_haiku: [
    provider: :anthropic,
    id: "claude-haiku-4-5"
  ],
  claude_opus: [
    provider: :anthropic,
    id: "claude-opus-4-8"
  ],
  gpt_5_5: [
    provider: :openai,
    id: "gpt-5.5"
  ],
  gpt_5_4_mini: [
    provider: :openai,
    id: "gpt-5.4-mini"
  ]

import_config "#{config_env()}.exs"
