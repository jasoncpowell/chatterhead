defmodule ChatterheadWeb.Router do
  use ChatterheadWeb, :router

  import ChatterheadWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ChatterheadWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ChatterheadWeb do
    pipe_through :browser

    post "/join", SessionController, :create
    delete "/leave", SessionController, :delete

    live_session :current_scope,
      on_mount: [{ChatterheadWeb.UserAuth, :mount_current_scope}] do
      live "/", LobbyLive, :index
    end

    live_session :joined,
      on_mount: [
        {ChatterheadWeb.UserAuth, :mount_current_scope},
        {ChatterheadWeb.UserAuth, :require_joined_user}
      ] do
      live "/room", RoomLive, :show
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", ChatterheadWeb do
  #   pipe_through :api
  # end
end
