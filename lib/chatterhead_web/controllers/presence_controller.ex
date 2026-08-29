defmodule ChatterheadWeb.PresenceController do
  @moduledoc """
  The endpoint a page beacons on its way out, so leaving the room is reflected
  at once rather than whenever the server notices the connection is gone.

  Presence is released when a LiveView process dies, and that only happens when
  its connection goes away — so the server's picture of who is online is only as
  prompt as the browser's goodbye. That goodbye is not dependable:

    * on the long-poll fallback it is an `XMLHttpRequest` the browser cancels
      as the page unloads, and nothing else about long-poll is connection-bound,
      so the session lingers until its inactivity timer fires;
    * on a WebSocket, `phoenix.js` defers `conn.close()` behind a `setTimeout`
      whenever the send buffer is not empty, and timers stop running once a page
      is unloading;
    * a page frozen into the back/forward cache is not torn down at all, so
      there is no socket close for the OS to deliver either.

  When the goodbye is lost, the user stays "online" to everyone else until the
  transport's own silence timer expires — 15–25s on the WebSocket, longer on
  long-poll. `navigator.sendBeacon/2` is the one request a browser undertakes to
  deliver after the page is gone, so `app.js` beacons here on `pagehide` and
  `ChatterheadWeb.Presence.untrack_page/2` drops that page's presence
  immediately.

  The beacon carries the page id, not a user id: it can only ever drop presence
  the session already owns, and only for the page that sent it.
  """
  use ChatterheadWeb, :controller

  alias Chatterhead.Accounts.Scope
  alias ChatterheadWeb.Presence

  @doc """
  Drops the beaconing page's presence. Always `204`: a beacon has no reader, and
  a page that was never tracked (the lobby) or has already been untracked (the
  socket closed first) is the ordinary case, not an error.
  """
  def away(conn, %{"page_id" => page_id}) when is_binary(page_id) do
    case conn.assigns.current_scope do
      %Scope{user: user} -> Presence.untrack_page(user, page_id)
      nil -> :ok
    end

    send_resp(conn, :no_content, "")
  end

  def away(conn, _params), do: send_resp(conn, :no_content, "")
end
