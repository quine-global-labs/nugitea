defmodule Nugitea.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    role = Application.fetch_env!(:nugitea, :role)

    if role == :app do
      storage = Application.fetch_env!(:nugitea, :storage_node)
      Node.connect(storage) || raise "can't reach storage node #{storage}"
    end

    children =
      if role in [:all, :app] do
        [{Bandit, plug: Nugitea.Router, port: Application.fetch_env!(:nugitea, :http_port)}]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: Nugitea.Supervisor)
  end
end
