defmodule Chatterhead.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS citext", "DROP EXTENSION IF EXISTS citext"

    create table(:users) do
      add :name, :citext, null: false
      add :last_seen_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:name])
  end
end
