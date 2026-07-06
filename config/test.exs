import Config

# Postgres for the Ecto lifecycle adapter tests. PG* env vars follow the
# usual conventions; defaults suit a local trust-auth server and CI's
# postgres service. Tests tagged :postgres are skipped when unreachable.
config :clementine, Clementine.TestRepo,
  username: System.get_env("PGUSER") || System.get_env("USER") || "postgres",
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  database: System.get_env("PGDATABASE", "clementine_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  log: false

# Test-specific configuration
config :clementine,
  anthropic_api_key: "test-anthropic-key",
  openai_api_key: "test-openai-key",
  log_level: :warning,
  # Use mock LLM in tests
  llm_client: Clementine.LLM.MockClient

# Configure Mox
config :clementine, :mox, verify_on_exit: true

# Register non-standard HTTP status codes used by Anthropic
config :plug, :statuses, %{529 => "Overloaded"}
