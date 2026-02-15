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
  ],
  gpt_5: [
    provider: :openai,
    model: "gpt-5",
    max_output_tokens: 4096
  ],
  gpt_5_codex: [
    provider: :openai,
    model: "gpt-5-codex",
    max_output_tokens: 4096
  ]

import_config "#{config_env()}.exs"
