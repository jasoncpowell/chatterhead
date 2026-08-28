defmodule Chatterhead.Accounts.Roster do
  @moduledoc """
  Who exists, and which of them are online.

  The persisted user list (`Accounts.list_users/0`) projected against the
  presence-derived online set (`ChatterheadWeb.Presence.online_users/0`) — a
  database LEFT JOIN presence, kept as a pure function so it is testable without
  a socket, a tracker, or a database.

  A LiveView builds one on mount, then folds the semantic presence events into
  it with `mark_online/2` and `mark_offline/2` — no re-query per event. The
  struct is opaque; `entries/1` and `counts/1` are the only ways to read it, so
  the display ordering can change without touching call sites.
  """

  alias Chatterhead.Accounts.Roster
  alias Chatterhead.Accounts.Roster.Entry
  alias Chatterhead.Accounts.User

  @opaque t :: %__MODULE__{by_id: %{integer() => Entry.t()}}

  defstruct by_id: %{}

  @doc """
  Builds a roster from every user and a snapshot of the online set.

  `users` is `[%User{}]`; `online` is `%{id => %{id:, name:}}`. Every user becomes
  an entry; an online id with no matching user (created since the list was
  loaded) still gets one.
  """
  @spec build([User.t()], %{integer() => %{id: integer(), name: String.t()}}) :: t()
  def build(users, online) do
    from_users =
      Map.new(users, fn %User{} = user ->
        {user.id,
         %Entry{
           id: user.id,
           name: user.name,
           online?: Map.has_key?(online, user.id),
           last_seen_at: user.last_seen_at
         }}
      end)

    by_id =
      Enum.reduce(online, from_users, fn {id, info}, acc ->
        Map.put_new(acc, id, %Entry{id: id, name: info.name, online?: true})
      end)

    %Roster{by_id: by_id}
  end

  @doc """
  Marks a user online, inserting the entry if this roster has not seen them —
  which is how a user created after the client mounted appears with no database
  round trip. Idempotent.
  """
  @spec mark_online(t(), %{id: integer(), name: String.t()}) :: t()
  def mark_online(%Roster{by_id: by_id} = roster, %{id: id, name: name}) do
    entry =
      case by_id do
        %{^id => existing} -> %{existing | online?: true}
        _ -> %Entry{id: id, name: name, online?: true}
      end

    %{roster | by_id: Map.put(by_id, id, entry)}
  end

  @doc """
  Marks a user offline and records when they left. A no-op for an id this roster
  has never seen.
  """
  @spec mark_offline(t(), %{id: integer(), at: DateTime.t()}) :: t()
  def mark_offline(%Roster{by_id: by_id} = roster, %{id: id, at: at}) do
    case by_id do
      %{^id => entry} ->
        %{roster | by_id: Map.put(by_id, id, %{entry | online?: false, last_seen_at: at})}

      _ ->
        roster
    end
  end

  @doc "Entries in display order: online first, then by name, case-insensitively."
  @spec entries(t()) :: [Entry.t()]
  def entries(%Roster{by_id: by_id}) do
    by_id
    |> Map.values()
    |> Enum.sort_by(&{not &1.online?, String.downcase(&1.name)})
  end

  @doc "`%{online: n, offline: n}` — derived from the entries, never stored."
  @spec counts(t()) :: %{online: non_neg_integer(), offline: non_neg_integer()}
  def counts(%Roster{by_id: by_id}) do
    Enum.reduce(by_id, %{online: 0, offline: 0}, fn {_id, entry}, acc ->
      key = if entry.online?, do: :online, else: :offline
      Map.update!(acc, key, &(&1 + 1))
    end)
  end
end
