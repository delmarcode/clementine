import Config

# Test-specific configuration
config :clementine,
  api_key: "test-api-key",
  log_level: :warning,
  # Use mock LLM in tests
  llm_client: Clementine.LLM.MockClient

# Configure Mox
config :clementine, :mox,
  verify_on_exit: true
