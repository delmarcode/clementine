defmodule Clementine.TestRepo do
  @moduledoc false

  use Ecto.Repo, otp_app: :clementine, adapter: Ecto.Adapters.Postgres
end
