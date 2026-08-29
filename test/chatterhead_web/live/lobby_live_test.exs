defmodule ChatterheadWeb.LobbyLiveTest do
  # async: false — this LiveView observes presence, a global unsandboxed process.
  use ChatterheadWeb.ConnCase, async: false

  import Chatterhead.PresenceCase

  alias Chatterhead.Accounts

  setup do
    on_exit(&drain_presence_fetchers/0)
    :ok
  end

  describe "join form" do
    test "renders the form and every persisted user, all offline", %{conn: conn} do
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

  describe "live presence" do
    test "a user in the room shows online, and offline again when they leave", %{conn: conn} do
      {:ok, user} = Accounts.join("mover")
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#roster-user-#{user.id}[data-online='false']")

      pid = track_user(user)

      eventually(fn ->
        assert has_element?(view, "#roster-user-#{user.id}[data-online='true']")
      end)

      stop_tracked(pid)

      eventually(fn ->
        assert has_element?(view, "#roster-user-#{user.id}[data-online='false']")
      end)
    end

    test "a lobby opened after someone is already online shows them online immediately", %{
      conn: conn
    } do
      {:ok, user} = Accounts.join("early-bird")
      track_user(user)

      # Wait until presence has actually converged, then mount — the snapshot must
      # carry them without needing a diff.
      eventually(fn -> assert Map.has_key?(ChatterheadWeb.Presence.online_users(), user.id) end)

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#roster-user-#{user.id}[data-online='true']")
    end

    test "a user tracked but not yet in the roster still appears", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      {:ok, latecomer} = Accounts.join("latecomer")
      track_user(latecomer)

      eventually(fn ->
        assert has_element?(view, "#roster-user-#{latecomer.id}[data-online='true']")
      end)
    end
  end
end
