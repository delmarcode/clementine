defmodule Clementine.TestPlatforms do
  @moduledoc false
  # Sets `config :clementine, :platforms` for one test: `entries` replace
  # the configured platforms of the same name, and the whole key is put
  # back when the test exits.

  import ExUnit.Callbacks, only: [on_exit: 1]

  def put(entries) do
    previous = Application.get_env(:clementine, :platforms)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:clementine, :platforms, previous),
        else: Application.delete_env(:clementine, :platforms)
    end)

    Application.put_env(:clementine, :platforms, Keyword.merge(previous || [], entries))
  end
end
