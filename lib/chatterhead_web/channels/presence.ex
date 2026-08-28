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
end
