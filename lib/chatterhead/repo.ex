defmodule Chatterhead.Repo do
  use Ecto.Repo,
    otp_app: :chatterhead,
    adapter: Ecto.Adapters.Postgres
end
