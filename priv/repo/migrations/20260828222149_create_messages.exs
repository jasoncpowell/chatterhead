defmodule Chatterhead.Repo.Migrations.CreateMessages do
  use Ecto.Migration

  def change do
    create table(:messages) do
      add :body, :text, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:messages, [:user_id])

    # Backs the keyset "load older" scan: `(inserted_at, id) < (cursor)` ordered
    # newest-first is an index range scan on this composite.
    create index(:messages, [:inserted_at, :id])
  end
end
