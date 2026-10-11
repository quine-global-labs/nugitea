defmodule Nugitea.CLI do
  @moduledoc """
  `nugitea` commands (`mix nugitea ...`, or `bin/nugitea ...`):

      serve                                   run HTTP, SSH and the mirror scheduler
      user create LOGIN | user list
      org create PATH [--visibility V]        PATH is `org` or `parent/child`
      org list
      repo create PATH [--visibility V]       PATH is `owner/name` or `org/sub/name`
      repo list
      mirror add-pull|add-push [--interval 5m] REPO URL
      graphql-schema                          print the GraphQL schema (SDL)

  Visibility is public (default), internal or private. `--state-dir` and
  `--storage-node` override NUGITEA_STATE_DIR and NUGITEA_STORAGE_NODE.
  """

  alias Nugitea.Accounts
  alias Nugitea.Accounts.Directory, as: D
  alias Nugitea.Storage.Client

  @switches [visibility: :string, interval: :string, state_dir: :string, storage_node: :string]

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

  defp run(["mirror", direction, repo, url], opts) when direction in ["add-pull", "add-push"] do
    start()

    with {:ok, seconds} <- parse_duration(opts[:interval] || "5m") do
      case direction do
        "add-pull" -> Nugitea.Mirror.add_pull(repo, url, seconds)
        "add-push" -> Nugitea.Mirror.add_push(repo, url, seconds)
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
