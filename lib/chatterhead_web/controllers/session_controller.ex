defmodule ChatterheadWeb.SessionController do
  @moduledoc """
  The join flow's cookie boundary: a plain controller, because a LiveView cannot
  write a session cookie.
  """
  use ChatterheadWeb, :controller

  alias Chatterhead.Accounts
  alias ChatterheadWeb.CoreComponents
  alias ChatterheadWeb.UserAuth

  @doc """
  Joins under `params["user"]["name"]` (nested because the lobby form is built
  from a `%User{}` changeset). Find-or-create, set the session, land in the room.
  On an invalid name — a rare path, since the form validates live over the
  socket — flash the first error and return to the lobby.
  """
  def create(conn, %{"user" => %{"name" => name}}) do
    case Accounts.join(name) do
      {:ok, user} ->
        conn
        |> UserAuth.log_in_user(user)
        |> redirect(to: ~p"/room")

      {:error, changeset} ->
        conn
        |> put_flash(:error, "That name won't work — #{first_name_error(changeset)}.")
        |> redirect(to: ~p"/")
    end
  end

  @doc "Clears the session and returns to the lobby."
  def delete(conn, _params) do
    conn
    |> UserAuth.log_out_user()
    |> redirect(to: ~p"/")
  end

  defp first_name_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&CoreComponents.translate_error/1)
    |> Map.get(:name, ["is invalid"])
    |> List.first()
  end
end
