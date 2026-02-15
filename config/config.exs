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
    id: "claude-sonnet-4-20250514",
    defaults: [max_tokens: 8192]
  ],
  claude_haiku: [
    provider: :anthropic,
    id: "claude-haiku-4-5-20250514",
    defaults: [max_tokens: 4096]
  ],
  claude_opus: [
    provider: :anthropic,
    id: "claude-opus-4-20250514",
    defaults: [max_tokens: 8192]
  ],
  gpt_5: [
    provider: :openai,
    id: "gpt-5",
    defaults: [max_output_tokens: 4096]
  ],
  gpt_5_codex: [
    provider: :openai,
    id: "gpt-5-codex",
    defaults: [max_output_tokens: 4096]
  ]

import_config "#{config_env()}.exs"
