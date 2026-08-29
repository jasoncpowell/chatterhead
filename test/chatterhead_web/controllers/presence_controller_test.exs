defmodule ChatterheadWeb.PresenceControllerTest do
  # async: false: Presence is a global, unsandboxed process.
  use ChatterheadWeb.ConnCase, async: false

  import Chatterhead.PresenceCase

  alias Chatterhead.Accounts
  alias ChatterheadWeb.Presence

  setup do
    on_exit(&drain_presence_fetchers/0)
    # A prior serial test's leave may still be converging; start from a clean slate.
    eventually(fn -> assert Presence.online_users() == %{} end)

    {:ok, user} = Accounts.join("beacon-user-#{System.unique_integer([:positive])}")
    %{user: user}
  end

  describe "POST /away" do
    test "drops the beaconing page's presence at once", %{conn: conn, user: user} do
      track_user(user, "page-a")
      eventually(fn -> assert Map.has_key?(Presence.online_users(), user.id) end)

      conn = conn |> log_in(user) |> post(~p"/away", page_id: "page-a")

      assert response(conn, 204)
      eventually(fn -> refute Map.has_key?(Presence.online_users(), user.id) end)
    end

    test "leaves the user's other pages online", %{conn: conn, user: user} do
      track_user(user, "page-a")
      track_user(user, "page-b")
      eventually(fn -> assert Map.has_key?(Presence.online_users(), user.id) end)

      conn |> log_in(user) |> post(~p"/away", page_id: "page-a")

      assert Map.has_key?(Presence.online_users(), user.id)
    end

    test "cannot drop a page held by another user", %{conn: conn, user: user} do
      {:ok, other} = Accounts.join("other-#{System.unique_integer([:positive])}")
      track_user(user, "page-a")
      eventually(fn -> assert Map.has_key?(Presence.online_users(), user.id) end)

      conn |> log_in(other) |> post(~p"/away", page_id: "page-a")

      assert Map.has_key?(Presence.online_users(), user.id)
    end

    test "a page id nobody holds is accepted and changes nothing", %{conn: conn, user: user} do
      track_user(user, "page-current")
      eventually(fn -> assert Map.has_key?(Presence.online_users(), user.id) end)

      conn = conn |> log_in(user) |> post(~p"/away", page_id: "page-already-closed")

      assert response(conn, 204)
      assert Map.has_key?(Presence.online_users(), user.id)
    end

    test "a beacon from a visitor who never joined is a no-op", %{conn: conn} do
      conn = post(conn, ~p"/away", page_id: "page-a")

      assert response(conn, 204)
    end

    test "a beacon with no page id is a no-op", %{conn: conn, user: user} do
      track_user(user, "page-a")
      eventually(fn -> assert Map.has_key?(Presence.online_users(), user.id) end)

      conn = conn |> log_in(user) |> post(~p"/away", %{})

      assert response(conn, 204)
      assert Map.has_key?(Presence.online_users(), user.id)
    end
  end
end
