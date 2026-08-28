defmodule Chatterhead.Accounts.UserTest do
  use Chatterhead.DataCase, async: true

  alias Chatterhead.Accounts.User

  describe "changeset/2" do
    test "trims surrounding whitespace" do
      changeset = User.changeset(%User{}, %{name: "  alice  "})

      assert changeset.valid?
      assert get_change(changeset, :name) == "alice"
    end

    test "collapses internal whitespace runs to a single space" do
      changeset = User.changeset(%User{}, %{name: "alice   the\t great"})

      assert changeset.valid?
      assert get_change(changeset, :name) == "alice the great"
    end

    test "requires a name" do
      changeset = User.changeset(%User{}, %{})

      refute changeset.valid?
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects blank and whitespace-only names" do
      for blank <- ["", "   ", "\t\n"] do
        changeset = User.changeset(%User{}, %{name: blank})

        refute changeset.valid?, "expected #{inspect(blank)} to be rejected"
        assert Map.has_key?(errors_on(changeset), :name)
      end
    end

    test "accepts a name at the 24-character boundary" do
      assert User.changeset(%User{}, %{name: String.duplicate("a", 24)}).valid?
    end

    test "rejects a name one character past the boundary" do
      changeset = User.changeset(%User{}, %{name: String.duplicate("a", 25)})

      refute changeset.valid?
      assert %{name: ["should be at most 24 character(s)"]} = errors_on(changeset)
    end

    test "rejects control characters in the name" do
      changeset = User.changeset(%User{}, %{name: "alice\abob"})

      refute changeset.valid?
      assert %{name: ["must not contain control characters"]} = errors_on(changeset)
    end

    test "does not cast last_seen_at" do
      changeset =
        User.changeset(%User{}, %{name: "alice", last_seen_at: ~U[2026-01-01 00:00:00Z]})

      assert get_change(changeset, :last_seen_at) == nil
    end
  end
end
