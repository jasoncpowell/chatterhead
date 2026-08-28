# Seed data for a fresh database.
#
#     mix run priv/repo/seeds.exs
#
# Idempotent: Accounts.join/1 is find-or-create, so this is safe to run
# repeatedly and is exactly what `mix ecto.reset` calls.
#
# Users only, no messages. The seeded users start offline, which is what makes
# requirement A1 -- "list all users", including ones who have never been online
# -- demonstrable in a single browser window.

alias Chatterhead.Accounts

for name <- ~w(alice bob carol dave erin) do
  {:ok, _user} = Accounts.join(name)
end
