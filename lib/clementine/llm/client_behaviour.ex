defmodule Clementine.LLM.ClientBehaviour do
  @moduledoc """
  Behaviour for LLM clients.

  This behaviour allows for mocking the LLM client in tests.
  """

  @type model :: atom()
  @type messages :: [map()]
  @type tools :: [module()]
  @type opts :: keyword()

  @type response :: %{
          content: [map()],
          stop_reason: String.t(),
          usage: map()
        }

  @callback call(model, String.t(), messages, tools, opts) ::
              {:ok, response()} | {:error, term()}

  @callback stream(model, String.t(), messages, tools, opts) ::
              Enumerable.t()
end
