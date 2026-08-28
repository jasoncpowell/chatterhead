defmodule ChatterheadWeb.Presence do
  @moduledoc """
  Presence tracking for the chat room.

  Connections are tracked on `topic/0`, keyed by the user's integer id cast to a
  string (`Phoenix.Presence` stringifies keys). The integer id and the name both
  travel in the *meta*, so:

    * no `fetch/2` callback is needed — which keeps the database out of
      Presence's fetcher processes and out of the Ecto sandbox's way in tests;
    * callers read the integer id straight from the meta and never parse the
      string key.

  From CHAT-4 commit 3 this module is also a *presence client*: `init/1` +
  `handle_metas/4` translate raw tracker diffs into semantic `{:user_online,
  ...}` / `{:user_offline, ...}` events on `events_topic/0`.
  """
  use Phoenix.Presence,
    otp_app: :chatterhead,
    pubsub_server: Chatterhead.PubSub

  alias Chatterhead.Accounts.User

  @topic "chat:presence"

  @doc """
  The topic connections are tracked on.

  Nothing subscribes here: raw `%Phoenix.Socket.Broadcast{event: "presence_diff"}`
  messages land on this topic and are consumed by the presence client. Semantic
  events are published on `events_topic/0` instead.
  """
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  The topic the presence client publishes semantic events on:

      {:user_online,  %{id: 7, name: "alice"}}
      {:user_offline, %{id: 7, name: "alice", at: ~U[2026-08-28 12:00:00Z]}}

  Both LiveViews subscribe here and never see a raw `presence_diff`.
  """
  @spec events_topic() :: String.t()
  def events_topic, do: "chat:presence:events"

  @doc """
  Tracks `pid` (a LiveView process) as `user` being present in the room.
  """
  @spec track_user(pid(), User.t()) :: {:ok, binary()} | {:error, term()}
  def track_user(pid, %User{} = user) do
    track(pid, @topic, to_string(user.id), %{
      id: user.id,
      name: user.name,
      online_at: DateTime.utc_now()
    })
  end

  @doc """
  The users currently present, keyed by integer id:

      %{7 => %{id: 7, name: "alice"}, 9 => %{id: 9, name: "bob"}}

  One entry per user regardless of how many tabs they hold open.
  """
  @spec online_users() :: %{integer() => %{id: integer(), name: String.t()}}
  def online_users do
    @topic
    |> list()
    |> Map.new(fn {_key, %{metas: [meta | _]}} ->
      {meta.id, %{id: meta.id, name: meta.name}}
    end)
  end

  # --- Presence client ---------------------------------------------------------
  #
  # Argument shapes, verified against deps/phoenix/lib/phoenix/presence.ex:
  #
  #   joins / leaves : %{key :: String.t() => %{metas: [meta, ...]}}
  #                    group/1 output passed through fetch/2. fetch/2 is NOT
  #                    implemented here, so it is the identity -- there is no
  #                    :user key, and the moduledoc's `presence.user` would raise.
  #
  #   presences      : %{key :: String.t() => [meta, ...]}   (a bare meta list)
  #                    Post-diff. A key is dropped entirely once its last meta
  #                    leaves, so `Map.has_key?(presences, key)` answers "are any
  #                    tabs for this user still open?".
  #
  #   meta           : %{id: integer, name: String.t(), online_at: DateTime.t()}
  #
  #   state          : %{topic => %{key => %{id: integer, name: String.t()}}}

  @impl Phoenix.Presence
  def init(_opts), do: {:ok, %{}}

  @impl Phoenix.Presence
  def handle_metas(topic, %{joins: joins, leaves: leaves}, presences, state) do
    at = DateTime.truncate(DateTime.utc_now(), :second)
    known = Map.get(state, topic, %{})

    known =
      Enum.reduce(joins, known, fn {key, %{metas: [meta | _]}}, acc ->
        if Map.has_key?(acc, key) do
          # Another tab for someone already online -- not a transition.
          acc
        else
          user = %{id: meta.id, name: meta.name}
          publish({:user_online, user})
          Map.put(acc, key, user)
        end
      end)

    known =
      Enum.reduce(leaves, known, fn {key, _presence}, acc ->
        if Map.has_key?(presences, key) do
          # Other tabs remain open; still online.
          acc
        else
          case Map.fetch(acc, key) do
            {:ok, user} ->
              publish({:user_offline, Map.put(user, :at, at)})
              Map.delete(acc, key)

            :error ->
              acc
          end
        end
      end)

    {:ok, Map.put(state, topic, known)}
  end

  # Events go to events_topic/0, never the `topic` argument (which is the tracked
  # topic -- publishing there would put semantic events alongside raw diffs and
  # undo the decoupling). local_broadcast/3, not broadcast/3: handle_metas/4 runs
  # on every node, so broadcast/3 would fan N^2 copies across a cluster.
  defp publish(message) do
    Phoenix.PubSub.local_broadcast(Chatterhead.PubSub, events_topic(), message)
  end
end
