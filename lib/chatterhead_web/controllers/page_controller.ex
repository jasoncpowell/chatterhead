defmodule ChatterheadWeb.PageController do
  use ChatterheadWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
