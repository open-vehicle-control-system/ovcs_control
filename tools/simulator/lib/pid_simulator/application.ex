defmodule PidSimulator.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: PidSimulator.PubSub},
      PidSimulatorWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: PidSimulator.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    PidSimulatorWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
