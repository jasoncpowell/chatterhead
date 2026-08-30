defmodule Chatterhead.Accounts do
  @moduledoc """
  Users and joining.

  This context is the roster's source of truth: every participant is a row in
  `users`, whether or not they are currently online. It knows nothing about
  `Phoenix.Presence`.
  """

  import Ecto.Query, warn: false

  alias Chatterhead.Accounts.User
  alias Chatterhead.Repo

  @doc """
  Finds the user with this name, or creates one.

  The name is normalised by `User.changeset/2` (trimmed, internal whitespace
  collapsed) and matched case-insensitively through the `citext` column.
  Returns `{:error, changeset}` for a name that fails validation.

  Safe against two callers racing to create the same brand-new name: the
  insert uses `ON CONFLICT DO NOTHING`, and the caller that loses the race
  re-reads the winning row.
  """
  @spec join(String.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def join(name) do
    changeset = User.changeset(%User{}, %{name: name})

    if changeset.valid? do
      canonical = Ecto.Changeset.get_field(changeset, :name)

      case Repo.get_by(User, name: canonical) do
        %User{} = user ->
          {:ok, user}

        nil ->
          case Repo.insert(changeset, on_conflict: :nothing, conflict_target: :name) do
            {:ok, %User{id: nil}} -> {:ok, Repo.get_by!(User, name: canonical)}
            {:ok, %User{} = user} -> {:ok, user}
          end
      end
    else
      {:error, %{changeset | action: :insert}}
    end
  end

  @doc """
  Every user, ordered by name ascending.

  `citext` makes the sort case-insensitive, so "alice", "Bob", "carol" come
  back in that order.
  """
  @spec list_users() :: [User.t()]
  def list_users do
    Repo.all(from u in User, order_by: [asc: u.name])
  end

  @spec get_user(term()) :: User.t() | nil
  def get_user(id), do: Repo.get(User, id)

  @spec get_user!(term()) :: User.t()
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Records `at` as the user's `last_seen_at`.

  One targeted `UPDATE`, no changeset and no read, so it is safe to call from
  any process — including the supervised task the presence client spawns on
  leave. A missing user id is a harmless no-op.

  Stored at second precision (`update_all` truncates the value). The presence
  client truncates `at` once at the source, so the timestamp it broadcasts and
  the one persisted here are identical and no client has to re-query.
  """
  @spec touch_last_seen(integer(), DateTime.t()) :: :ok
  def touch_last_seen(user_id, %DateTime{} = at) do
    Repo.update_all(from(u in User, where: u.id == ^user_id), set: [last_seen_at: at])
    :ok
  end

  @doc """
  A changeset for join and validation forms, without exposing the schema module
  to the web layer.
  """
  @spec change_user(User.t(), map()) :: Ecto.Changeset.t()
  def change_user(user \\ %User{}, attrs \\ %{})

  def change_user(%User{} = user, attrs) do
    User.changeset(user, attrs)
  end
end
