defmodule Chatterhead.Accounts.RosterTest do
  use ExUnit.Case, async: true

  alias Chatterhead.Accounts.Roster
  alias Chatterhead.Accounts.User

  defp user(id, name, last_seen_at \\ nil) do
    %User{id: id, name: name, last_seen_at: last_seen_at}
  end

  defp online(users) do
    Map.new(users, fn {id, name} -> {id, %{id: id, name: name}} end)
  end

  describe "build/2" do
    test "an empty online map marks everyone offline" do
      roster = Roster.build([user(1, "alice"), user(2, "bob")], %{})

      assert Enum.all?(Roster.entries(roster), &(&1.online? == false))
      assert Roster.counts(roster) == %{online: 0, offline: 2}
    end

    test "marks exactly the users present in the online map" do
      roster =
        Roster.build([user(1, "alice"), user(2, "bob"), user(3, "carol")], online(%{2 => "bob"}))

      by_name = Map.new(Roster.entries(roster), &{&1.name, &1.online?})
      assert by_name == %{"alice" => false, "bob" => true, "carol" => false}
    end

    test "carries last_seen_at through from the user" do
      at = ~U[2026-01-01 12:00:00Z]
      roster = Roster.build([user(1, "alice", at)], %{})

      assert [%{name: "alice", last_seen_at: ^at}] = Roster.entries(roster)
    end

    test "represents an online id with no matching user row" do
      roster = Roster.build([user(1, "alice")], online(%{2 => "ghost"}))

      assert [%{name: "alice"}, %{name: "ghost", online?: true, last_seen_at: nil}] =
               Enum.sort_by(Roster.entries(roster), & &1.name)
    end
  end

  describe "mark_online/2" do
    test "adds an entry for an id the roster has not seen" do
      roster =
        Roster.build([user(1, "alice")], %{})
        |> Roster.mark_online(%{id: 2, name: "bob"})

      assert [%{id: 2, name: "bob", online?: true}] =
               Enum.filter(Roster.entries(roster), &(&1.id == 2))
    end

    test "flips a known user online and is idempotent" do
      roster =
        Roster.build([user(1, "alice", ~U[2026-01-01 00:00:00Z])], %{})
        |> Roster.mark_online(%{id: 1, name: "alice"})
        |> Roster.mark_online(%{id: 1, name: "alice"})

      assert [%{id: 1, online?: true}] = Roster.entries(roster)
      assert Roster.counts(roster) == %{online: 1, offline: 0}
    end
  end

  describe "mark_offline/2" do
    test "flips a user offline and records last_seen_at from at" do
      at = ~U[2026-02-02 09:30:00Z]

      roster =
        Roster.build([user(1, "alice")], online(%{1 => "alice"}))
        |> Roster.mark_offline(%{id: 1, at: at})

      assert [%{id: 1, online?: false, last_seen_at: ^at}] = Roster.entries(roster)
    end

    test "is a no-op for an unknown id" do
      roster = Roster.build([user(1, "alice")], %{})
      assert Roster.mark_offline(roster, %{id: 99, at: ~U[2026-01-01 00:00:00Z]}) == roster
    end
  end

  describe "entries/1" do
    test "puts online before offline, then sorts case-insensitively by name" do
      roster =
        Roster.build(
          [user(1, "carol"), user(2, "alice"), user(3, "Bob"), user(4, "Dave")],
          online(%{3 => "Bob", 1 => "carol"})
        )

      assert Enum.map(Roster.entries(roster), & &1.name) == ~w(Bob carol alice Dave)
    end
  end

  describe "counts/1" do
    test "always matches the partition sizes of entries/1" do
      roster =
        Roster.build(
          [user(1, "a"), user(2, "b"), user(3, "c"), user(4, "d")],
          online(%{1 => "a", 3 => "c"})
        )

      entries = Roster.entries(roster)
      counts = Roster.counts(roster)

      assert counts.online == Enum.count(entries, & &1.online?)
      assert counts.offline == Enum.count(entries, &(not &1.online?))
      assert counts.online + counts.offline == length(entries)
    end
  end
end
