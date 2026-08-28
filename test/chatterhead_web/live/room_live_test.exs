defmodule ChatterheadWeb.RoomLiveTest do
  # async: false — CHAT-11 makes this LiveView track and observe presence.
  use ChatterheadWeb.ConnCase, async: false

  alias Chatterhead.Accounts

  test "a visitor with no session is redirected to the lobby", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/room")
  end

  test "a joined user reaches the room", %{conn: conn} do
    {:ok, user} = Accounts.join("roomie")

    {:ok, view, _html} = conn |> log_in(user) |> live(~p"/room")

    assert render(view) =~ "roomie"
  end
end
