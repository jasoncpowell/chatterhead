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
end
