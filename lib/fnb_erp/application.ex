defmodule FnbErp.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      FnbErpWeb.Telemetry,
      FnbErp.Repo,
      {DNSCluster, query: Application.get_env(:fnb_erp, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: FnbErp.PubSub},
      # Start a worker by calling: FnbErp.Worker.start_link(arg)
      # {FnbErp.Worker, arg},
      # Start to serve requests, typically the last entry
      FnbErpWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: FnbErp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FnbErpWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
