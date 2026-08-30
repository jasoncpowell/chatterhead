defmodule ChatterheadWeb.PresenceController do
  @moduledoc """
  The endpoint a page beacons on its way out, so leaving the room is reflected
  at once rather than whenever the server notices the connection is gone.

  Presence is released only when the LiveView process's connection goes away,
  and a browser tearing a page down is not a dependable narrator of that —
  see the README's "Going offline promptly" section for the full rationale
  (WebSocket close deferred by `phoenix.js`, long-poll's goodbye cancelled
  outright, the back/forward cache freezing a page with no socket close at
  all). This is the path that doesn't wait for any of that:
  `navigator.sendBeacon/2` is the one request a browser undertakes to deliver
  after the page is gone, so `app.js` beacons here on `pagehide`.

  The beacon carries the page id, not a user id, so it can only ever drop
  presence the session already owns, and only for the page that sent it — see
  `ChatterheadWeb.Presence.untrack_page/2`.
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
