defmodule Clementine.LLM.ClientBehaviour do
  @moduledoc """
  Behaviour for LLM clients.

  This behaviour allows for mocking the LLM client in tests.
  """

  @type model :: Clementine.LLM.ModelRegistry.model_ref()
  @type messages :: [Clementine.LLM.Message.message()]
  @type tools :: [module()]
  # `:deferred` names tools in `tools` the model may load on demand; a
  # client without tool search sends them as ordinary tools (see
  # `Clementine.LLM.call/5`).
  @type opts :: keyword()

  @type response :: Clementine.LLM.Response.t()

  @callback call(model, String.t(), messages, tools, opts) ::
              {:ok, response()} | {:error, term()}

  @callback stream(model, String.t(), messages, tools, opts) ::
              Enumerable.t()
end
