defmodule ChatterheadWeb.UserAuth do
  @moduledoc """
  Carries identity — a `%Chatterhead.Accounts.Scope{}` — through the request
  (`fetch_current_scope/2` plug) and the LiveView socket (`on_mount` hooks), and
  writes or clears the session cookie (`log_in_user/2`, `log_out_user/1`).

  A LiveView runs over a WebSocket and cannot set a cookie, so joining is a plain
  controller POST. These hooks are what then let both LiveViews agree on who you
  are without each re-reading the session.
  """

  use ChatterheadWeb, :verified_routes

  import Plug.Conn

  alias Chatterhead.Accounts
  alias Chatterhead.Accounts.Scope
  alias Chatterhead.Accounts.User

  @doc """
  Plug: assigns `:current_scope` from the `:user_id` in the session, or `nil`
  when there is none or it points at a user that no longer exists.
  """
  def fetch_current_scope(conn, _opts) do
    assign(conn, :current_scope, scope_from(get_session(conn, :user_id)))
  end

  @doc """
  `on_mount` hooks:

    * `:mount_current_scope` — assigns `:current_scope` (possibly `nil`) from the
      session, via `assign_new/3` so the lookup runs at most once per socket.
    * `:require_joined_user` — halts and redirects to `/` unless a user has
      joined. Listed after `:mount_current_scope` in the room's `live_session`.
  """
  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont,
     Phoenix.Component.assign_new(socket, :current_scope, fn ->
       scope_from(session["user_id"])
     end)}
  end

  def on_mount(:require_joined_user, _params, _session, socket) do
    case socket.assigns[:current_scope] do
      %Scope{user: %User{}} ->
        {:cont, socket}

      _ ->
        {:halt,
         socket
         |> Phoenix.LiveView.put_flash(:error, "Join the chat to enter the room.")
         |> Phoenix.LiveView.redirect(to: ~p"/")}
    end
  end

  @doc """
  Renews the session id (session-fixation hygiene) and records the joined user.
  The caller redirects.

  Also stamps a `live_socket_id`. `Phoenix.LiveView.Socket.id/1` reads that key
  out of the session, which makes every LiveView connection this user opens
  addressable on one topic — the handle `log_out_user/1` needs.
  """
  def log_in_user(conn, %User{} = user) do
    conn
    |> renew_session()
    |> put_session(:user_id, user.id)
    |> put_session(:live_socket_id, live_socket_id(user))
  end

  @doc """
  Renews the session id, drops the joined user, and closes their live
  connections.

  The disconnect is what makes Leave take effect at once. Clearing the cookie
  alone leaves the room's LiveView process running — it is torn down only when
  its connection goes away, and that is the browser's decision, taken on its own
  schedule (see `ChatterheadWeb.PresenceController`). Until then the process
  holds its presence and everyone else still sees the user in the room, for as
  long as the transport takes to notice the silence. Leaving is something the
  server knows for certain, so it does not wait to be told: broadcasting
  `"disconnect"` stops those sockets here and `Phoenix.Presence` untracks them
  in milliseconds.

  Every tab goes, not just the one that clicked Leave — the session they shared
  is gone, so none of them are joined any more.
  """
  def log_out_user(conn) do
    if live_socket_id = get_session(conn, :live_socket_id) do
      ChatterheadWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    renew_session(conn)
  end

  defp live_socket_id(%User{id: id}), do: "users_socket:#{id}"

  defp scope_from(user_id) when is_integer(user_id) do
    case Accounts.get_user(user_id) do
      %User{} = user -> Scope.for_user(user)
      nil -> nil
    end
  end

  defp scope_from(_), do: nil

  defp renew_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end
end
