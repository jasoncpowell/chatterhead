defmodule ChatterheadWeb.LobbyLiveTest do
  # async: false — CHAT-8 makes this LiveView observe presence.
  use ChatterheadWeb.ConnCase, async: false

  alias Chatterhead.Accounts

  test "renders the join form and every persisted user", %{conn: conn} do
    {:ok, alice} = Accounts.join("alice-lobby")
    {:ok, bob} = Accounts.join("bob-lobby")

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#join-form")
    assert has_element?(view, "#roster-user-#{alice.id}[data-online='false']")
    assert has_element?(view, "#roster-user-#{bob.id}[data-online='false']")
  end

  test "phx-change with a blank name shows a validation error", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html = view |> form("#join-form", user: %{name: ""}) |> render_change()

    assert html =~ "blank"
  end

  test "a joined visitor sees a link back to the room instead of the form", %{conn: conn} do
    {:ok, user} = Accounts.join("returning")

    {:ok, view, _html} = conn |> log_in(user) |> live(~p"/")

    refute has_element?(view, "#join-form")
    assert has_element?(view, ~s(a[href="/room"]))
  end
end
