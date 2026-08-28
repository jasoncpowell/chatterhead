defmodule Chatterhead.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ChatterheadWeb.Telemetry,
      Chatterhead.Repo,
      {DNSCluster, query: Application.get_env(:chatterhead, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Chatterhead.PubSub},
      # Owned separately from ChatterheadWeb.Presence.TaskSupervisor (which runs
      # Presence's own fetchers). handle_metas/4 spawns last_seen_at writes here,
      # so it must start before Presence.
      {Task.Supervisor, name: Chatterhead.TaskSupervisor},
      # Presence depends on the PubSub server above and must start before the
      # endpoint so tracking is available as soon as connections arrive.
      ChatterheadWeb.Presence,
      # Start to serve requests, typically the last entry
      ChatterheadWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Chatterhead.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ChatterheadWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
