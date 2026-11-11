defmodule Nugitea.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    role = Application.fetch_env!(:nugitea, :role)

    if storage = Application.fetch_env!(:nugitea, :storage_node) do
      Node.connect(storage) || raise "can't reach storage node #{storage}"
    end

    children =
      if role in [:all, :app] and Application.fetch_env!(:nugitea, :serve) do
        [
          {Bandit, plug: Nugitea.Router, port: Application.fetch_env!(:nugitea, :http_port)},
          Nugitea.SSH,
          Nugitea.Mirror.Scheduler
        ]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: Nugitea.Supervisor)
  end
end
