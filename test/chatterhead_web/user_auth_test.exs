defmodule ChatterheadWeb.UserAuthTest do
  use ChatterheadWeb.ConnCase, async: true

  alias Chatterhead.Accounts
  alias Chatterhead.Accounts.Scope
  alias Chatterhead.Accounts.User
  alias ChatterheadWeb.UserAuth

  setup %{conn: conn} do
    {:ok, user} = Accounts.join("auth-user")
    %{conn: Phoenix.ConnTest.init_test_session(conn, %{}), user: user}
  end

  describe "fetch_current_scope/2" do
    test "assigns a scope for a session with a valid user_id", %{conn: conn, user: user} do
      conn = conn |> put_session(:user_id, user.id) |> UserAuth.fetch_current_scope([])

      assert %Scope{user: %User{id: id}} = conn.assigns.current_scope
      assert id == user.id
    end

    test "assigns nil when there is no session user_id", %{conn: conn} do
      conn = UserAuth.fetch_current_scope(conn, [])

      assert conn.assigns.current_scope == nil
    end

    test "assigns nil when the session points at a user that no longer exists", %{conn: conn} do
      conn = conn |> put_session(:user_id, -1) |> UserAuth.fetch_current_scope([])

      assert conn.assigns.current_scope == nil
    end
  end

  describe "log_in_user/2" do
    test "renews the session id and records the user", %{conn: conn, user: user} do
      conn =
        conn
        |> put_session(:stale, "value")
        |> UserAuth.log_in_user(user)

      assert get_session(conn, :user_id) == user.id
      assert get_session(conn, :stale) == nil
      assert conn.private.plug_session_info == :renew
    end
  end

  describe "log_out_user/1" do
    test "drops the user and renews the session id", %{conn: conn, user: user} do
      conn =
        conn
        |> put_session(:user_id, user.id)
        |> UserAuth.log_out_user()

      assert get_session(conn, :user_id) == nil
      assert conn.private.plug_session_info == :renew
    end
  end

  describe "on_mount :mount_current_scope" do
    test "assigns a scope from the session", %{user: user} do
      socket = mount_socket()

      assert {:cont, socket} =
               UserAuth.on_mount(:mount_current_scope, %{}, %{"user_id" => user.id}, socket)

      assert %Scope{user: %User{id: id}} = socket.assigns.current_scope
      assert id == user.id
    end

    test "assigns nil with no session user_id" do
      socket = mount_socket()

      assert {:cont, socket} = UserAuth.on_mount(:mount_current_scope, %{}, %{}, socket)
      assert socket.assigns.current_scope == nil
    end
  end

  describe "on_mount :require_joined_user" do
    test "continues when a scope is present", %{user: user} do
      socket = mount_socket(current_scope: Scope.for_user(user))

      assert {:cont, _socket} = UserAuth.on_mount(:require_joined_user, %{}, %{}, socket)
    end

    test "halts and redirects to / when there is no scope" do
      socket = mount_socket(current_scope: nil)

      assert {:halt, socket} = UserAuth.on_mount(:require_joined_user, %{}, %{}, socket)
      assert {:redirect, %{to: "/"}} = socket.redirected
    end
  end

  defp mount_socket(assigns \\ []) do
    base = %{__changed__: %{}, flash: %{}}
    %Phoenix.LiveView.Socket{assigns: Enum.into(assigns, base)}
  end
end
