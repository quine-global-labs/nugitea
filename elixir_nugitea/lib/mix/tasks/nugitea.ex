defmodule Mix.Tasks.Nugitea do
  @shortdoc "nugitea commands: serve, user, org, repo, mirror, graphql-schema"
  @moduledoc "See `Nugitea.CLI`."
  use Mix.Task

  @impl true
  def run(argv) do
    Mix.Task.run("app.config")
    # Only `serve` starts the servers.
    Application.put_env(:nugitea, :serve, false)
    Nugitea.CLI.main(argv)
  end
end
