defmodule Chatterhead.AccountsTest do
  use Chatterhead.DataCase, async: true

  alias Chatterhead.Accounts
  alias Chatterhead.Accounts.User

  describe "join/1" do
    test "creates a user on the first call" do
      assert {:ok, %User{id: id, name: "alice"}} = Accounts.join("alice")
      assert is_integer(id)
    end

    test "returns the same user on a second call" do
      assert {:ok, %User{id: id}} = Accounts.join("alice")
      assert {:ok, %User{id: ^id}} = Accounts.join("alice")
      assert Repo.aggregate(User, :count) == 1
    end

    test "resolves names case-insensitively to one user" do
      assert {:ok, %User{id: id, name: "Jason"}} = Accounts.join("Jason")
      assert {:ok, %User{id: ^id, name: "Jason"}} = Accounts.join("jason")
      assert Repo.aggregate(User, :count) == 1
    end

    test "stores the normalised name" do
      assert {:ok, %User{name: "alice smith"}} = Accounts.join("  alice   smith ")
    end

    test "returns an error changeset for an invalid name and inserts nothing" do
      assert {:error, %Ecto.Changeset{valid?: false}} = Accounts.join("   ")
      assert Repo.aggregate(User, :count) == 0
    end

    test "the database, not just the changeset, rejects a duplicate name" do
      {:ok, _} = Accounts.join("alice")

      assert_raise Ecto.ConstraintError, fn -> Repo.insert(%User{name: "ALICE"}) end
    end
  end

  describe "list_users/0" do
    test "returns every user, name-ascending and case-insensitive" do
      for name <- ~w(carol alice Bob), do: {:ok, _} = Accounts.join(name)

      assert Enum.map(Accounts.list_users(), & &1.name) == ~w(alice Bob carol)
    end
  end

  describe "change_user/2" do
    test "returns a changeset over a User" do
      assert %Ecto.Changeset{data: %User{}} = Accounts.change_user(%User{})
    end
  end

  describe "touch_last_seen/2" do
    test "records the timestamp on the user row" do
      {:ok, user} = Accounts.join("toucher")
      at = DateTime.truncate(DateTime.utc_now(), :second)

      assert :ok = Accounts.touch_last_seen(user.id, at)
      assert Accounts.get_user!(user.id).last_seen_at == at
    end

    test "stores at second precision" do
      {:ok, user} = Accounts.join("toucher-usec")

      :ok = Accounts.touch_last_seen(user.id, ~U[2026-01-01 12:00:00.654321Z])

      assert Accounts.get_user!(user.id).last_seen_at == ~U[2026-01-01 12:00:00Z]
    end

    test "is a harmless no-op for an unknown user id" do
      assert :ok = Accounts.touch_last_seen(-1, DateTime.truncate(DateTime.utc_now(), :second))
    end
  end
end
