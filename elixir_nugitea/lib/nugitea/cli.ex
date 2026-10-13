defmodule Nugitea.CLI do
  @moduledoc """
  `nugitea` commands (`mix nugitea ...`, or `bin/nugitea ...`):

      serve                                   run HTTP, SSH and the mirror scheduler
      user create LOGIN | user list
      org create PATH [--visibility V]        PATH is `org` or `parent/child`
      org list
      org add-member ORG USER [--role member|owner|billing_manager]
      repo create PATH [--visibility V]       PATH is `owner/name` or `org/sub/name`
      repo list
      repo set-topics PATH "topic1 topic2"
      repo delete PATH
      team create ORG SLUG                    ORG is `org` or `parent/child`
      team add-member ORG/SLUG USER           USER is a login
      grant USER|ORG/TEAM REPO_OR_ORG_PATH ROLE
      mirror add-pull|add-push [--interval 5m] REPO URL
      webhook add REPO URL [--secret S]
      webhook list
      graphql-schema                          print the GraphQL schema (SDL)
      token create USER                       create a new access token for USER

  Visibility is public (default), internal or private. `--state-dir` and
  `--storage-node` override NUGITEA_STATE_DIR and NUGITEA_STORAGE_NODE.
  """

  alias Nugitea.Accounts
  alias Nugitea.Accounts.Directory, as: D
  alias Nugitea.Storage.Client

  @switches [
    visibility: :string,
    interval: :string,
    state_dir: :string,
    storage_node: :string,
    role: :string,
    secret: :string
  ]

  def main(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: @switches)
    if dir = opts[:state_dir], do: Application.put_env(:nugitea, :state_dir, Path.expand(dir))

    if node = opts[:storage_node] do
      Application.put_env(:nugitea, :storage_node, String.to_atom(node))
    end

    case run(args, opts) do
      :ok -> :ok
      {:error, msg} -> Mix.raise(to_string(msg))
    end
  end

  defp run(["serve"], _opts) do
    Application.put_env(:nugitea, :serve, true)
    start()
    Process.sleep(:infinity)
  end

  defp run(["graphql-schema"], _opts) do
    IO.write(Absinthe.Schema.to_sdl(Nugitea.GraphQL.Schema))
  end

  defp run(["user", "create", login], _opts) do
    start()

    with {:ok, _} <- Accounts.Store.update(Accounts.state_dir(), &D.add_user(&1, login)),
         do: IO.puts(login)
  end

  defp run(["org", "create", path], opts) do
    start()

    with {:ok, vis} <- visibility(opts),
         {:ok, id} <- Accounts.Store.update(Accounts.state_dir(), &D.add_org_at(&1, path, vis)) do
      {:ok, dir} = Accounts.Store.load(Accounts.state_dir())
      IO.puts(D.path(dir, id))
    end
  end

  defp run(["org", "add-member", org_path, user_login], opts) do
    start()

    with {:ok, role} <- role(opts),
         {:ok, dir} <- Accounts.Store.load(Accounts.state_dir()),
         org_id <- D.resolve(dir, org_path),
         user_id <- D.resolve(dir, user_login),
         :ok <-
           Accounts.Store.update(
             Accounts.state_dir(),
             &D.set_org_member(&1, org_id, user_id, role)
           ) do
      :ok
    end
  end

  defp run(["repo", "create", path], opts) do
    start()
    state = Accounts.state_dir()

    # Validate against the directory (owner exists, name free, visibility
    # allowed) before touching storage, and record the repo only once the
    # bare repo exists there.
    with {:ok, vis} <- visibility(opts),
         {:ok, dir} <- Accounts.Store.load(state),
         {:ok, dry_run, id} <- D.add_repo_at(dir, path, vis),
         canonical = D.repo_path(dry_run, id),
         :ok <- Client.init_bare(canonical),
         {:ok, _} <- Accounts.Store.update(state, &D.add_repo_at(&1, canonical, vis)) do
      IO.puts(canonical)
    end
  end

  defp run(["team", "create", org_path, slug], opts) do
    start()

    with {:ok, vis} <- visibility(opts),
         {:ok, id} <-
           Accounts.Store.update(
             Accounts.state_dir(),
             &D.add_team_at(&1, org_path, slug, nil, vis)
           ) do
      {:ok, dir} = Accounts.Store.load(Accounts.state_dir())
      IO.puts(D.path(dir, id))
    end
  end

  defp run(["team", "add-member", team_path, user_login], _opts) do
    start()

    with {:ok, dir} <- Accounts.Store.load(Accounts.state_dir()),
         team_id <- D.resolve(dir, team_path),
         user_id <- D.resolve(dir, user_login),
         :ok <-
           Accounts.Store.update(
             Accounts.state_dir(),
             &D.set_team_member(&1, team_id, user_id, :member)
           ) do
      :ok
    end
  end

  defp run([kind, "list"], _opts) when kind in ["user", "org", "repo"] do
    start()
    {:ok, dir} = Accounts.Store.load(Accounts.state_dir())

    paths =
      case kind do
        "repo" -> Enum.map(D.repos(dir), &D.repo_path(dir, &1.id))
        "org" -> for a <- D.accounts(dir), D.org?(a), do: D.path(dir, a.id)
        "user" -> for a <- D.accounts(dir), not D.org?(a), do: D.path(dir, a.id)
      end

    paths |> Enum.sort() |> Enum.each(&IO.puts/1)
  end

  defp run(["grant", principal, resource, role], _opts) do
    start()

    with {:ok, dir} <- Accounts.Store.load(Accounts.state_dir()),
         principal_id <- D.resolve(dir, principal),
         resource_id <- D.resolve(dir, resource) do
      # Use Directory.grant to implement the command
      case D.grant(dir, {:user, principal_id}, {:repo, resource_id}, role) do
        {:ok, new_dir} ->
          Accounts.Store.update(Accounts.state_dir(), fn _ -> new_dir end)
          :ok

        {:error, reason} ->
          {:error, "grant failed: #{reason}"}
      end
    end
  end

  defp run(["mirror", direction, repo, url], opts) when direction in ["add-pull", "add-push"] do
    start()

    with {:ok, seconds} <- parse_duration(opts[:interval] || "5m") do
      case direction do
        "add-pull" -> Nugitea.Mirror.add_pull(repo, url, seconds)
        "add-push" -> Nugitea.Mirror.add_push(repo, url, seconds)
      end
    end
  end

  defp run(["token", "create", user_login], _opts) do
    start()

    with {:ok, dir} <- Accounts.Store.load(Accounts.state_dir()),
         user_id <- D.resolve(dir, user_login),
         token <- Nugitea.Accounts.Tokens.create_token(Accounts.state_dir(), user_id) do
      IO.puts(token)
    end
  end

  defp run(["user", "add-key", user_login, key], _opts) do
    start()

    with {:ok, dir} <- Accounts.Store.load(Accounts.state_dir()),
         user_id <- D.resolve(dir, user_login),
         {:ok, updated_dir} <- D.add_user_key(dir, user_id, key) do
      Accounts.Store.update(Accounts.state_dir(), fn _ -> updated_dir end)
      IO.puts("SSH key added for #{user_login}")
    end
  end

  defp run(["webhook", "add", repo, url], opts) do
    start()

    with secret <- opts[:secret],
         {:ok, _} <-
           Nugitea.Webhooks.Store.update(
             Accounts.state_dir(),
             &Map.put(&1, repo, %{url: url, secret: secret})
           ) do
      IO.puts("Webhook added for #{repo}")
    end
  end

  defp run(["webhook", "list"], _opts) do
    start()

    with {:ok, webhooks} <- Nugitea.Webhooks.Store.load(Accounts.state_dir()) do
      webhooks
      |> Enum.each(fn {repo, webhook} ->
        secret = if webhook.secret, do: " (secret: #{webhook.secret})", else: ""
        IO.puts("#{repo} -> #{webhook.url}#{secret}")
      end)
    end
  end

  defp run(["repo", "set-topics", path, topics_str], _opts) do
    start()

    with {:ok, dir} <- Accounts.Store.load(Accounts.state_dir()),
         repo_id <- D.resolve_repo(dir, path),
         topics = String.split(topics_str, " ", trim: true) do
      case Accounts.Store.update(Accounts.state_dir(), &D.set_repo_topics(&1, repo_id, topics)) do
        {:ok, _} -> IO.puts("Topics set for #{path}")
        {:error, reason} -> {:error, "Failed to set topics: #{reason}"}
      end
    end
  end

  defp run(["repo", "delete", path], _opts) do
    start()

    with {:ok, dir} <- Accounts.Store.load(Accounts.state_dir()),
         repo_id <- D.resolve_repo(dir, path) do
      # Delete the repository from both directory and storage
      case Accounts.Store.update(
             Accounts.state_dir(),
             &D.delete_repo(&1, repo_id)
           ) do
        {:ok, updated_dir} ->
          # Now delete the actual git repository directory on disk
          canonical_path = D.repo_path(updated_dir, repo_id)

          case Client.delete(canonical_path) do
            :ok ->
              IO.puts("Repository #{path} deleted")

            {:error, reason} ->
              {:error, "Failed to delete repository from disk: #{reason}"}
          end

        {:error, reason} ->
          {:error, "Failed to delete repository from directory: #{reason}"}
      end
    end
  end

  defp run(_args, _opts), do: {:error, "usage:\n" <> @moduledoc}

  # Starts the app (servers only for `serve`). Reaching a storage node on
  # another host needs distribution, so a CLI run joins as a throwaway node.
  defp start do
    if Application.get_env(:nugitea, :storage_node) && not Node.alive?() do
      System.cmd("epmd", ["-daemon"])

      {:ok, _} =
        Node.start(:"nugitea-cli-#{System.unique_integer([:positive])}", name_domain: :shortnames)
    end

    {:ok, _} = Application.ensure_all_started(:nugitea)
  end

  def role(opts) do
    case opts[:role] || "member" do
      r when r in ~w(member owner billing_manager) -> {:ok, String.to_existing_atom(r)}
      r -> {:error, "invalid role #{inspect(r)}: expected member, owner, or billing_manager"}
    end
  end

  defp visibility(opts) do
    case opts[:visibility] || "public" do
      v when v in ~w(public internal private) -> {:ok, String.to_existing_atom(v)}
      v -> {:error, "invalid visibility #{inspect(v)}: expected public, internal, or private"}
    end
  end

  @doc "A single-unit duration: `30s`, `5m`, `2h`."
  def parse_duration(s) do
    case Integer.parse(String.trim(s)) do
      {n, "s"} when n >= 0 -> {:ok, n}
      {n, "m"} when n >= 0 -> {:ok, n * 60}
      {n, "h"} when n >= 0 -> {:ok, n * 3600}
      _ -> {:error, "invalid duration #{inspect(s)}: expected a number with s, m, or h"}
    end
  end
end
