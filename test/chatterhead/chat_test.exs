defmodule Chatterhead.ChatTest do
  use Chatterhead.DataCase, async: true

  alias Chatterhead.Accounts
  alias Chatterhead.Accounts.User
  alias Chatterhead.Chat
  alias Chatterhead.Chat.Message

  setup do
    {:ok, user} = Accounts.join("chat-test-user")
    %{user: user}
  end

  describe "list_recent/1" do
    test "returns the page oldest-first with user preloaded", %{user: user} do
      seed_messages(user, 5)

      {page, more?} = Chat.list_recent(10)

      assert Enum.map(page, & &1.body) == ~w(m1 m2 m3 m4 m5)
      refute more?
      assert Enum.all?(page, &match?(%User{}, &1.user))
    end

    test "breaks ties on id when inserted_at is identical", %{user: user} do
      at = ~U[2026-01-01 00:00:00.000000Z]

      first =
        Repo.insert!(%Message{user_id: user.id, body: "first", inserted_at: at, updated_at: at})

      later =
        Repo.insert!(%Message{user_id: user.id, body: "later", inserted_at: at, updated_at: at})

      {page, _} = Chat.list_recent(10)

      assert Enum.map(page, & &1.id) == [first.id, later.id]
    end

    test "more? is true when a full page plus one exists", %{user: user} do
      seed_messages(user, Chat.page_size() + 1)

      assert {page, true} = Chat.list_recent()
      assert length(page) == Chat.page_size()
    end

    test "more? is false when history is exactly one page", %{user: user} do
      seed_messages(user, Chat.page_size())

      assert {page, false} = Chat.list_recent()
      assert length(page) == Chat.page_size()
    end

    test "returns an empty page for empty history" do
      assert {[], false} = Chat.list_recent()
    end
  end

  describe "list_before/2" do
    test "returns the page before the cursor, excluding the cursor row, oldest-first", %{
      user: user
    } do
      [_m1, _m2, _m3, m4, _m5, _m6] = seed_messages(user, 6)

      {page, more?} = Chat.list_before(Chat.cursor(m4), 10)

      assert Enum.map(page, & &1.body) == ~w(m1 m2 m3)
      refute more?
      assert Enum.all?(page, &match?(%User{}, &1.user))
    end

    test "tiles the history with list_recent: no gap, no overlap", %{user: user} do
      seed_messages(user, 10)

      {recent, true} = Chat.list_recent(4)
      {older, true} = Chat.list_before(Chat.cursor(List.first(recent)), 4)
      {oldest, false} = Chat.list_before(Chat.cursor(List.first(older)), 4)

      assert Enum.map(older ++ recent, & &1.body) == ~w(m3 m4 m5 m6 m7 m8 m9 m10)
      assert Enum.map(oldest, & &1.body) == ~w(m1 m2)
    end

    test "new inserts between two calls neither duplicate nor skip a message", %{user: user} do
      [_m1, _m2, _m3, _m4, m5, _m6, _m7, _m8] = seed_messages(user, 8)

      {first_back, true} = Chat.list_before(Chat.cursor(m5), 2)
      assert Enum.map(first_back, & &1.body) == ~w(m3 m4)

      # A newer message arrives; it must not disturb a keyset scan anchored to a row.
      Repo.insert!(%Message{
        user_id: user.id,
        body: "m9",
        inserted_at: ~U[2026-01-01 00:00:09.000000Z],
        updated_at: ~U[2026-01-01 00:00:09.000000Z]
      })

      {second_back, false} = Chat.list_before(Chat.cursor(List.first(first_back)), 5)
      assert Enum.map(second_back, & &1.body) == ~w(m1 m2)
    end
  end

  defp seed_messages(user, n) do
    base = ~U[2026-01-01 00:00:00.000000Z]

    entries =
      for i <- 1..n do
        at = DateTime.add(base, i, :second)
        %{user_id: user.id, body: "m#{i}", inserted_at: at, updated_at: at}
      end

    {^n, _} = Repo.insert_all(Message, entries)
    Repo.all(from m in Message, order_by: [asc: m.inserted_at, asc: m.id])
  end
end
