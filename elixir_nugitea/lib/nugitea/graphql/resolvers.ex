defmodule Nugitea.GraphQL.Resolvers do
  @moduledoc """
  Resolvers for `Nugitea.GraphQL.Schema`. Each root field loads one snapshot
  of the accounts directory, and every object it returns carries that
  snapshot, so a response is consistent with itself. Repos the authorizer
  won't let you pull resolve to null or are left out of lists, the way
  GitHub returns null for a repo you can't see.
  """

  alias Nugitea.Accounts
  alias Nugitea.Accounts.Directory, as: D
  alias Nugitea.Storage.Client

  # ---- root ---------------------------------------------------------------

  @doc "Interfaces (RepositoryOwner, GitObject, ...): every object carries its concrete type."
  def resolve_type(%{__type: type}, _), do: type

  def repository(_, %{owner: owner, name: name}, _) do
    dir = snapshot()
    {:ok, dir |> D.resolve_repo("#{owner}/#{name}") |> repo(dir)}
  end

  def repository_owner(_, %{login: login}, _) do
    dir = snapshot()
    {:ok, dir |> D.resolve(login) |> owner(dir)}
  end

  def user(p, args, r), do: only(repository_owner(p, args, r), :user)
  def organization(p, args, r), do: only(repository_owner(p, args, r), :organization)

  defp only({:ok, %{__type: type} = o}, type), do: {:ok, o}
  defp only(_, _), do: {:ok, nil}

  @doc """
  Resolves a URL or path to the user, org or repo it names. Walks owner
  segments until one names a repo, then stops, so `/a/repo/tree/main/src`
  still resolves to the repo.
  """
  def resource(_, %{url: url}, _) do
    dir = snapshot()
    segs = url_segments(url)

    found =
      segs
      |> Enum.with_index(1)
      |> Enum.find_value(fn {_, i} ->
        prefix = segs |> Enum.take(i) |> Enum.join("/")
        if D.resolve(dir, prefix), do: nil, else: {:repo, D.resolve_repo(dir, prefix)}
      end)

    {:ok,
     case {segs, found} do
       {[], _} -> nil
       {_, {:repo, id}} -> repo(id, dir)
       {_, nil} -> dir |> D.resolve(Enum.join(segs, "/")) |> owner(dir)
     end}
  end

  def all_repositories(_, args, _) do
    dir = snapshot()
    {:ok, connection(dir, Enum.map(D.repos(dir), & &1.id), args)}
  end

  # ---- owners -------------------------------------------------------------

  def owned_repositories(%{dir: dir, key: id}, args, _) do
    {:ok, connection(dir, Enum.map(D.repos_owned_by(dir, id), & &1.id), args)}
  end

  def parent_organization(%{dir: dir, key: id}, _, _) do
    {:ok, dir |> D.account(id) |> D.parent() |> owner(dir)}
  end

  def sub_organizations(%{dir: dir, key: id}, args, _) do
    nodes = dir |> D.child_orgs(id) |> Enum.sort_by(& &1.slug) |> Enum.map(&owner(&1.id, dir))
    {:ok, page(nodes, args)}
  end

  # ---- repos ------------------------------------------------------------

  def repo_owner(%{dir: dir, key: id}, _, _) do
    {:ok, dir |> D.repo(id) |> Map.fetch!(:owner) |> owner(dir)}
  end

  @doc "`main` if it exists, else `master`, else the first branch, else null."
  def default_branch_ref(%{path: path}, _, _) do
    with {:ok, branches} <- Client.branches(path) do
      default =
        Enum.find(["main", "master"], &(&1 in branches)) || Enum.min(branches, fn -> nil end)

      {:ok, default && %{name: default}}
    end
  end

  def refs(%{path: path}, _, _) do
    with {:ok, branches} <- Client.branches(path), do: {:ok, Enum.map(branches, &%{name: &1})}
  end

  def files(%{path: path}, %{ref: ref}, _), do: Client.files(path, ref)

  @doc """
  A `"ref"` or `"ref:path"` expression as a Tree or Blob. Tried as a tree
  first; if that fails on a non-empty path, as a blob: git decides which it
  is, not the shape of the string.
  """
  def object(%{path: repo}, %{expression: expression}, _) do
    {ref, path} =
      case String.split(expression, ":", parts: 2) do
        [ref, path] -> {ref, path}
        [ref] -> {ref, ""}
      end

    case Client.tree(repo, ref, path) do
      {:ok, entries} ->
        # Nothing reads a tree's own oid yet, only its entries' (as in rust_nugitea).
        {:ok,
         %{
           __type: :tree,
           oid: "",
           entries:
             Enum.map(entries, &%{name: &1.name, type: Atom.to_string(&1.kind), oid: &1.sha})
         }}

      {:error, _} when path == "" ->
        {:ok, nil}

      {:error, _} ->
        case Client.blob(repo, ref, path) do
          {:ok, %{sha: sha, content: content}} ->
            binary? = not String.valid?(content) or String.contains?(content, <<0>>)

            {:ok,
             %{
               __type: :blob,
               oid: sha,
               is_binary: binary?,
               text: if(binary?, do: nil, else: content),
               byte_size: byte_size(content)
             }}

          {:error, _} ->
            {:ok, nil}
        end
    end
  end

  # ---- shared -------------------------------------------------------------

  defp snapshot do
    {:ok, dir} = Accounts.Store.load(Accounts.state_dir())
    dir
  end

  defp repo(nil, _dir), do: nil

  defp repo(id, dir) do
    path = D.repo_path(dir, id)

    if path && Nugitea.Auth.allow_pull?(path) do
      r = D.repo(dir, id)

      %{
        __type: :repository,
        dir: dir,
        key: id,
        id: "R_#{id}",
        path: path,
        name: r.slug,
        name_with_owner: path,
        resource_path: "/" <> path,
        visibility: r.visibility,
        is_private: r.visibility == :private
      }
    end
  end

  defp owner(nil, _dir), do: nil

  defp owner(id, dir) do
    case D.account(dir, id) do
      nil ->
        nil

      a ->
        {type, prefix} = if D.org?(a), do: {:organization, "O"}, else: {:user, "U"}
        path = D.path(dir, id)

        %{
          __type: type,
          dir: dir,
          key: id,
          id: "#{prefix}_#{id}",
          login: path,
          resource_path: "/" <> path
        }
    end
  end

  defp connection(dir, ids, args) do
    ids
    |> Enum.map(&repo(&1, dir))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.path)
    |> page(args)
  end

  defp page(nodes, args) do
    nodes_page = if n = args[:first], do: Enum.take(nodes, max(n, 0)), else: nodes
    %{nodes: nodes_page, total_count: length(nodes)}
  end

  # A full URL or just a path, down to its path segments.
  defp url_segments(url) do
    path =
      case String.split(url, "://", parts: 2) do
        [_, rest] -> rest |> String.split("/", parts: 2) |> Enum.at(1, "")
        [path] -> path
      end

    path |> String.split(["?", "#"]) |> hd() |> String.split("/", trim: true)
  end
end
