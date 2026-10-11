import Config

# NUGITEA_ROLE picks which tier this node runs:
#   all     (default) both tiers in one node, like Gitea
#   app     HTTP, SSH and the mirror scheduler; runs no git, reaches NUGITEA_STORAGE_NODE
#   storage owns NUGITEA_REPO_ROOT and runs every git process
role =
  case System.get_env("NUGITEA_ROLE", "all") do
    r when r in ~w(all app storage) -> String.to_atom(r)
    other -> raise "NUGITEA_ROLE must be all, app or storage, not #{inspect(other)}"
  end

storage_node =
  case {role, System.get_env("NUGITEA_STORAGE_NODE")} do
    {:app, nil} -> raise "NUGITEA_ROLE=app needs NUGITEA_STORAGE_NODE, e.g. storage@host"
    {_, nil} -> nil
    {_, name} -> String.to_atom(name)
  end

config :nugitea,
  role: role,
  storage_node: storage_node,
  # The storage tier's git data.
  repo_root: Path.expand(System.get_env("NUGITEA_REPO_ROOT", "data/repos")),
  # The app tier's own state: accounts.json and mirrors.json.
  state_dir: Path.expand(System.get_env("NUGITEA_STATE_DIR", "data")),
  http_port: String.to_integer(System.get_env("NUGITEA_HTTP_PORT", "3080")),
  ssh_port: String.to_integer(System.get_env("NUGITEA_SSH_PORT", "2222")),
  ssh_host_key_dir: Path.expand(System.get_env("NUGITEA_SSH_HOST_KEY_DIR", "data/ssh")),
  # Start the servers on boot. Off for tests and for CLI commands.
  serve: config_env() != :test
