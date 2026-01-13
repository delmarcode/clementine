ExUnit.start()

# Define Mox mocks
Mox.defmock(Clementine.LLM.MockClient, for: Clementine.LLM.ClientBehaviour)

# Set Mox to verify on exit for all tests
Application.put_env(:clementine, :llm_client, Clementine.LLM.MockClient)
