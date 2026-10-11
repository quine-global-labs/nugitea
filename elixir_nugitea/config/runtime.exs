import Config

# NUGITEA_ROLE picks which tier this node runs:
#   all     (default) both tiers in one node, like Gitea
#   app     HTTP for git clients; runs no git itself, reaches NUGITEA_STORAGE_NODE
#   storage owns NUGITEA_REPO_ROOT and runs every git process
role =
  case System.get_env("NUGITEA_ROLE", "all") do
    r when r in ~w(all app storage) -> String.to_atom(r)
    other -> raise "NUGITEA_ROLE must be all, app or storage, not #{inspect(other)}"
  end

storage_node =
  case {role, System.get_env("NUGITEA_STORAGE_NODE")} do
    {:app, nil} -> raise "NUGITEA_ROLE=app needs NUGITEA_STORAGE_NODE, e.g. storage@host"
    {:app, name} -> String.to_atom(name)
    _ -> nil
  end

config :nugitea,
  role: role,
  storage_node: storage_node,
  repo_root: Path.expand(System.get_env("NUGITEA_REPO_ROOT", "data")),
  http_port: String.to_integer(System.get_env("NUGITEA_HTTP_PORT", "3080"))
