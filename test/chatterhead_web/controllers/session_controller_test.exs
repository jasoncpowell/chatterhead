defmodule ChatterheadWeb.SessionControllerTest do
  use ChatterheadWeb.ConnCase, async: true

  alias Chatterhead.Accounts
  alias Chatterhead.Accounts.User
  alias Chatterhead.Repo

  describe "POST /join" do
    test "a valid name creates the user, sets the session, and redirects to /room", %{conn: conn} do
      conn = post(conn, ~p"/join", user: %{name: "newcomer"})

      assert redirected_to(conn) == ~p"/room"
      assert %User{name: "newcomer"} = Accounts.get_user!(get_session(conn, :user_id))
    end

    test "an existing name in any casing reuses the row", %{conn: conn} do
      {:ok, user} = Accounts.join("Existing")
      count = Repo.aggregate(User, :count)

      conn = post(conn, ~p"/join", user: %{name: "EXISTING"})

      assert get_session(conn, :user_id) == user.id
      assert Repo.aggregate(User, :count) == count
    end

    test "a blank name returns to / with an error and creates nothing", %{conn: conn} do
      conn = post(conn, ~p"/join", user: %{name: "   "})

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "won't work"
      assert Repo.aggregate(User, :count) == 0
    end
  end

  describe "DELETE /leave" do
    test "clears the session and redirects to /", %{conn: conn} do
      {:ok, user} = Accounts.join("leaver")

      conn = conn |> log_in(user) |> delete(~p"/leave")

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_id) == nil
    end
  end
end
