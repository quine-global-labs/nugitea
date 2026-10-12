defmodule Nugitea.Accounts.Directory do
  @moduledoc """
  Users, orgs, teams and enterprises: one model that can express how Gitea,
  GitHub and GitLab each arrange them (see rust_nugitea's accounts/mod.rs for
  the long comparison). Persisted as accounts.json by `Nugitea.Accounts.Store`.
  Memberships, grants and `effective_access/3` aren't enforced yet: the
  authorizer is still allow-all, since nothing logs in.

  - One account namespace for users and orgs. An org may have a parent org;
    GitHub and Gitea are the depth-1 case of GitLab's tree. Slugs are unique,
    case-insensitively, among siblings; users and top-level orgs are siblings.
  - Org membership is inherited down the tree. Owners get admin on every repo
    beneath; members get the org's base role; billing managers aren't members.
  - Teams belong to one org and may nest (a child inherits its parent's
    grants); secret teams can't nest; team members must be org members.
  - Access is one list of grants of a built-in or custom role to a user or
    team, on an org (flowing down) or a repo. Effective access is the max.
  - Enterprises group top-level orgs and never own repos. One with a
    shortcode is managed (EMU): its users are `handle_shortcode`, confined to
    it, and can't own public repos.
  - Visibility is private < internal < public; a child is never more visible
    than its parent.
  - An account can block a user from everything beneath it.

  Every change returns `{:ok, dir}` or `{:ok, dir, id}`, or `{:error, reason}`
  with the directory untouched.
  """

  alias Nugitea.Names

  # First path segments taken by app-tier and web routes.
  @reserved ~w(api enterprises graphql login repos settings)
  @roles [:read, :triage, :write, :maintain, :admin]
  @org_roles [:billing_manager, :member, :owner]
  @visibilities [:private, :internal, :public]

  defstruct next_id: 0,
            accounts: %{},
            enterprises: %{},
            teams: %{},
            repos: %{},
            custom_roles: %{},
            # org -> user -> org role
            org_members: %{},
            # enterprise -> user -> :owner | :billing_manager
            enterprise_roles: %{},
            # {blocker account, blocked user}
            blocks: MapSet.new(),
            # %{principal: {:user | :team, id}, resource: {:org | :repo, id},
            #   role: role | {:custom, id}}
            grants: [],
            # user_id -> [key_info] 
            user_keys: %{}

  def roles, do: @roles
  def visibilities, do: @visibilities

  # ---- role mappings ----------------------------------------------------

  @doc "GitHub repo permissions, including the REST API's pull/push aliases."
  def role_from_github(p) when p in ["read", "pull"], do: :read
  def role_from_github("triage"), do: :triage
  def role_from_github(p) when p in ["write", "push"], do: :write
  def role_from_github("maintain"), do: :maintain
  def role_from_github("admin"), do: :admin
  def role_from_github(_), do: nil

  @doc "GitLab access levels; below Reporter can't read code, so no role."
  def role_from_gitlab(level) when level < 20, do: nil
  def role_from_gitlab(level) when level < 30, do: :read
  def role_from_gitlab(level) when level < 40, do: :write
  def role_from_gitlab(level) when level < 50, do: :maintain
  def role_from_gitlab(_), do: :admin

  @doc "Gitea AccessMode values (none=0, read, write, admin, owner=4)."
  def role_from_gitea(1), do: :read
  def role_from_gitea(2), do: :write
  def role_from_gitea(mode) when mode in [3, 4], do: :admin
  def role_from_gitea(_), do: nil

  defp rank(list, x), do: Enum.find_index(list, &(&1 == x))
  defp max_role(nil, b), do: b
  defp max_role(a, nil), do: a
  defp max_role(a, b), do: if(rank(@roles, a) >= rank(@roles, b), do: a, else: b)
  defp more_visible?(a, b), do: rank(@visibilities, a) > rank(@visibilities, b)
  defp member_role?(role), do: role in [:member, :owner]

  @doc "Get keys for a user by ID"
  def get_user_keys(dir, user_id) do
    dir.user_keys[user_id]
  end

  @doc "Add an SSH key for a user"
  def add_user_key(dir, user_id, key) do
    # Check that the user exists
    case Map.get(dir.accounts, user_id) do
      nil ->
        {:error, "user not found"}

      %{kind: :user} ->
        keys = dir.user_keys[user_id] || []
        # Avoid adding duplicate keys
        if Enum.any?(keys, &(&1.key == key)) do
          {:ok, dir}
        else
          updated_user_keys = Map.put(dir.user_keys, user_id, keys ++ [%{key: key}])
          {:ok, %{dir | user_keys: updated_user_keys}}
        end

      _ ->
        {:error, "not a user account"}
    end
  end

  # ---- lookups ----------------------------------------------------------

  def account(dir, id), do: dir.accounts[id]
  def repo(dir, id), do: dir.repos[id]
  def team(dir, id), do: dir.teams[id]
  def accounts(dir), do: Map.values(dir.accounts)
  def repos(dir), do: Map.values(dir.repos)
  def repos_owned_by(dir, owner), do: for(r <- repos(dir), r.owner == owner, do: r)
  def child_orgs(dir, org), do: for(a <- accounts(dir), parent(a) == org, do: a)

  def org?(account), do: account.kind == :org
  def parent(account), do: Map.get(account, :parent)

  defp fetch_org(dir, id) do
    case dir.accounts[id] do
      %{kind: :org} = a -> {:ok, a}
      _ -> {:error, "no org with id #{id}"}
    end
  end

  defp fetch_user(dir, id) do
    case dir.accounts[id] do
      %{kind: :user} = a -> {:ok, a}
      _ -> {:error, "no user with id #{id}"}
    end
  end

  defp fetch(map, id, what) do
    case map[id] do
      nil -> {:error, "no #{what} with id #{id}"}
      x -> {:ok, x}
    end
  end

  defp check(true, _msg), do: :ok
  defp check(false, msg), do: {:error, msg}

  defp alloc(dir), do: {%{dir | next_id: dir.next_id + 1}, dir.next_id + 1}

  defp eq_ci?(a, b), do: String.downcase(a) == String.downcase(b)

  # ---- structure --------------------------------------------------------

  # Slug syntax, and nothing under `parent` (nil = the root) already uses
  # it: child orgs and repos share one path space, as in GitLab.
  defp check_slug(dir, parent, slug) do
    taken =
      Enum.any?(accounts(dir), &(parent(&1) == parent and eq_ci?(&1.slug, slug))) or
        (parent != nil and Enum.any?(repos(dir), &(&1.owner == parent and eq_ci?(&1.slug, slug))))

    with :ok <- Names.validate(slug),
         :ok <-
           check(
             not String.ends_with?(String.downcase(slug), ".git"),
             "slug #{inspect(slug)} can't end in .git"
           ),
         :ok <-
           check(
             parent != nil or not Enum.any?(@reserved, &eq_ci?(&1, slug)),
             "slug #{inspect(slug)} is reserved"
           ) do
      check(not taken, "slug #{inspect(slug)} is already taken")
    end
  end

  defp insert_user(dir, slug, managed_by) do
    {dir, id} = alloc(dir)
    user = %{id: id, slug: slug, visibility: :public, kind: :user, managed_by: managed_by}
    {:ok, put_in(dir.accounts[id], user), id}
  end

  def add_user(dir, slug) do
    with :ok <- check_slug(dir, nil, slug), do: insert_user(dir, slug, nil)
  end

  @doc "Creates an EMU account named `<handle>_<shortcode>`."
  def add_managed_user(dir, enterprise, handle) do
    with {:ok, e} <- fetch(dir.enterprises, enterprise, "enterprise"),
         :ok <- check(e.shortcode != nil, "only a managed enterprise has managed users"),
         slug = "#{handle}_#{e.shortcode}",
         :ok <- check_slug(dir, nil, slug) do
      insert_user(dir, slug, enterprise)
    end
  end

  def add_org(dir, slug, parent, visibility) do
    with :ok <-
           if(parent,
             do: check(match?({:ok, _}, fetch_org(dir, parent)), "parent must be an org"),
             else: :ok
           ),
         :ok <- check_slug(dir, parent, slug),
         :ok <-
           check(
             parent == nil or not more_visible?(visibility, dir.accounts[parent].visibility),
             "org #{inspect(slug)} can't be more visible than its parent"
           ) do
      {dir, id} = alloc(dir)

      org = %{
        id: id,
        slug: slug,
        visibility: visibility,
        kind: :org,
        parent: parent,
        enterprise: nil,
        base_role: nil
      }

      {:ok, put_in(dir.accounts[id], org), id}
    end
  end

  @doc "`add_org/4` by full path: `acme/platform` creates `platform` under `acme`."
  def add_org_at(dir, path, visibility) do
    case String.split(path, "/") |> Enum.split(-1) do
      {[], [slug]} ->
        add_org(dir, slug, nil, visibility)

      {owners, [slug]} ->
        p = Enum.join(owners, "/")

        case resolve(dir, p) do
          nil -> {:error, "no org #{inspect(p)}"}
          parent -> add_org(dir, slug, parent, visibility)
        end
    end
  end

  def set_base_role(dir, org, role) do
    with {:ok, _} <- fetch_org(dir, org), do: {:ok, put_in(dir.accounts[org].base_role, role)}
  end

  @doc "A shortcode makes it a managed (EMU) enterprise."
  def add_enterprise(dir, slug, shortcode \\ nil) do
    with :ok <- Names.validate(slug),
         :ok <-
           check(
             not Enum.any?(Map.values(dir.enterprises), &eq_ci?(&1.slug, slug)),
             "enterprise #{inspect(slug)} already exists"
           ),
         :ok <-
           check(
             shortcode == nil or shortcode =~ ~r/\A[A-Za-z0-9]+\z/,
             "invalid shortcode #{inspect(shortcode)}"
           ),
         :ok <-
           check(
             shortcode == nil or
               not Enum.any?(
                 Map.values(dir.enterprises),
                 &(&1.shortcode && eq_ci?(&1.shortcode, shortcode))
               ),
             "shortcode #{inspect(shortcode)} is already taken"
           ) do
      {dir, id} = alloc(dir)
      {:ok, put_in(dir.enterprises[id], %{id: id, slug: slug, shortcode: shortcode}), id}
    end
  end

  @doc """
  Attaches a top-level org to an enterprise, or moves it. Moving into a
  managed enterprise requires everyone involved with the org to be one of
  its managed users.
  """
  def set_org_enterprise(dir, org, enterprise) do
    with :ok <-
           if(enterprise, do: fetch(dir.enterprises, enterprise, "enterprise") |> ok(), else: :ok),
         {:ok, o} <- fetch_org(dir, org),
         :ok <- check(o.parent == nil, "only top-level orgs belong to an enterprise directly") do
      moved = put_in(dir.accounts[org].enterprise, enterprise)

      case Enum.find(
             users_involved_in(moved, org),
             &(check_enterprise_boundary(moved, org, &1) != :ok)
           ) do
        nil -> {:ok, moved}
        bad -> {:error, "user #{bad} can't belong to an org in this enterprise"}
      end
    end
  end

  defp ok({:ok, _}), do: :ok
  defp ok(err), do: err

  def add_team(dir, org, slug, parent, privacy) do
    with {:ok, _} <- fetch_org(dir, org),
         :ok <- Names.validate(slug),
         :ok <-
           check(
             not Enum.any?(Map.values(dir.teams), &(&1.org == org and eq_ci?(&1.slug, slug))),
             "team #{inspect(slug)} already exists in this org"
           ),
         :ok <- check_team_parent(dir, org, parent, privacy) do
      {dir, id} = alloc(dir)
      team = %{id: id, org: org, parent: parent, slug: slug, privacy: privacy, members: %{}}
      {:ok, put_in(dir.teams[id], team), id}
    end
  end

  defp check_team_parent(_dir, _org, nil, _privacy), do: :ok

  defp check_team_parent(dir, org, parent, privacy) do
    with {:ok, p} <- fetch(dir.teams, parent, "team"),
         :ok <- check(p.org == org, "a parent team must be in the same org") do
      check(p.privacy != :secret and privacy != :secret, "secret teams can't be nested")
    end
  end

  def add_repo(dir, owner, slug, visibility) do
    with {:ok, o} <- fetch(dir.accounts, owner, "account"),
         :ok <- check_slug(dir, owner, slug),
         :ok <-
           check(
             not more_visible?(visibility, o.visibility),
             "repo #{inspect(slug)} can't be more visible than its owner"
           ),
         :ok <-
           check(
             not (Map.get(o, :managed_by) != nil and visibility == :public),
             "managed users can't own public repos"
           ) do
      {dir, id} = alloc(dir)

      {:ok, put_in(dir.repos[id], %{id: id, owner: owner, slug: slug, visibility: visibility}),
       id}
    end
  end

  @doc "`add_repo/4` by full path: `acme/platform/api` is `api` owned by `acme/platform`."
  def add_repo_at(dir, path, visibility) do
    case String.split(path, "/") |> Enum.split(-1) do
      {[], _} ->
        {:error, "repo #{inspect(path)} needs an owner"}

      {owners, [slug]} ->
        o = Enum.join(owners, "/")

        case resolve(dir, o) do
          nil -> {:error, "no user or org #{inspect(o)}"}
          owner -> add_repo(dir, owner, slug, visibility)
        end
    end
  end

  @doc "`add_team/5` by full path: `acme/devs` is `devs` in org `acme`."
  def add_team_at(dir, path, slug, parent, visibility) do
    case String.split(path, "/") |> Enum.split(-1) do
      {[], [_]} ->
        {:error, "team #{inspect(path)} needs an org"}

      {owners, [_]} ->
        o = Enum.join(owners, "/")

        case resolve(dir, o) do
          nil -> {:error, "no org #{inspect(o)}"}
          org -> add_team(dir, org, slug, parent, visibility)
        end
    end
  end

  def add_custom_role(dir, org, name, base, permissions) do
    with {:ok, _} <- fetch_org(dir, org),
         :ok <- Names.validate(name),
         :ok <-
           check(
             String.downcase(name) not in Enum.map(@roles, &Atom.to_string/1) and
               not Enum.any?(
                 Map.values(dir.custom_roles),
                 &(&1.org == org and eq_ci?(&1.name, name))
               ),
             "role #{inspect(name)} already exists"
           ) do
      {dir, id} = alloc(dir)
      role = %{id: id, org: org, name: name, base: base, permissions: MapSet.new(permissions)}
      {:ok, put_in(dir.custom_roles[id], role), id}
    end
  end

  # ---- membership -------------------------------------------------------

  @doc """
  Sets (a role) or removes (nil) a user's direct role in an org. Removal, or
  demotion to billing manager, drops everything they no longer qualify for
  beneath the org: team seats and every grant. An org can't lose its last
  owner.
  """
  def set_org_member(dir, org, user, role) do
    members = Map.get(dir.org_members, org, %{})
    owners = Enum.count(members, fn {_, r} -> r == :owner end)

    with {:ok, _} <- fetch_org(dir, org),
         {:ok, _} <- fetch_user(dir, user),
         :ok <- if(role, do: check_can_touch(dir, org, user), else: :ok),
         :ok <-
           check(
             not (members[user] == :owner and role != :owner and owners == 1),
             "can't remove an org's last owner"
           ) do
      members = if role, do: Map.put(members, user, role), else: Map.delete(members, user)
      dir = put_in(dir.org_members[org], members)
      {:ok, if(member_role?(role), do: dir, else: prune_nonmember(dir, org, user))}
    end
  end

  defp prune_nonmember(dir, org, user) do
    orphaned =
      for o <- subtree(dir, org), not org_member?(dir, o, user), into: MapSet.new(), do: o

    teams =
      Map.new(dir.teams, fn {id, t} ->
        {id, if(t.org in orphaned, do: update_in(t.members, &Map.delete(&1, user)), else: t)}
      end)

    drop_user_grants_within(%{dir | teams: teams}, user, orphaned)
  end

  @doc "The user's role in an org, direct or inherited from an ancestor."
  def org_role(dir, org, user) do
    ancestors(dir, org)
    |> Enum.map(&get_in(dir.org_members, [&1.id, user]))
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&rank(@org_roles, &1), fn -> nil end)
  end

  def org_member?(dir, org, user), do: member_role?(org_role(dir, org, user))

  @doc "Sets (a role) or removes (nil) a team seat; they must be in the team's org."
  def set_team_member(dir, team, user, role) do
    with {:ok, _} <- fetch_user(dir, user),
         {:ok, t} <- fetch(dir.teams, team, "team"),
         :ok <-
           check(
             role == nil or org_member?(dir, t.org, user),
             "team members must be members of the team's org"
           ) do
      members = if role, do: Map.put(t.members, user, role), else: Map.delete(t.members, user)
      {:ok, put_in(dir.teams[team].members, members)}
    end
  end

  # Teams the user is on, plus every ancestor of those.
  defp teams_of(dir, user) do
    for t <- Map.values(dir.teams), Map.has_key?(t.members, user), reduce: MapSet.new() do
      acc -> team_chain(dir, t, acc)
    end
  end

  defp team_chain(_dir, nil, acc), do: acc

  defp team_chain(dir, t, acc) do
    if t.id in acc, do: acc, else: team_chain(dir, dir.teams[t.parent], MapSet.put(acc, t.id))
  end

  @doc "Enterprise roles administer the enterprise; they grant no repo access."
  def set_enterprise_role(dir, enterprise, user, role) do
    with {:ok, e} <- fetch(dir.enterprises, enterprise, "enterprise"),
         {:ok, _} <- fetch_user(dir, user),
         :ok <-
           check(
             not (e.shortcode != nil and role != nil and enterprise_of(dir, user) != enterprise),
             "a managed enterprise's roles can only go to its managed users"
           ) do
      roles = Map.get(dir.enterprise_roles, enterprise, %{})
      roles = if role, do: Map.put(roles, user, role), else: Map.delete(roles, user)
      {:ok, put_in(dir.enterprise_roles[enterprise], roles)}
    end
  end

  def enterprise_role(dir, enterprise, user), do: get_in(dir.enterprise_roles, [enterprise, user])

  @doc "Its managed users, plus members of any of its orgs."
  def enterprise_member?(dir, enterprise, user) do
    enterprise_of(dir, user) == enterprise or
      Enum.any?(dir.org_members, fn {org, members} ->
        enterprise_of(dir, org) == enterprise and member_role?(members[user])
      end)
  end

  @doc "The enterprise an account falls under: its own for a managed user, its root org's for an org."
  def enterprise_of(dir, account) do
    case List.last(ancestors(dir, account)) do
      nil -> nil
      %{kind: :user} = root -> root.managed_by
      root -> root.enterprise
    end
  end

  # ---- grants and blocks ------------------------------------------------

  @doc """
  Records a grant, replacing any for the same principal and resource. Teams
  and custom roles only reach within their own org's subtree; org-wide grants
  to a user require membership (repo grants don't: outside collaborators).
  """
  def grant(dir, {pkind, pid} = principal, {rkind, rid} = resource, role) do
    within =
      case rkind do
        :org -> with {:ok, o} <- fetch_org(dir, rid), do: {:ok, o.id}
        :repo -> with {:ok, r} <- fetch(dir.repos, rid, "repo"), do: {:ok, r.owner}
      end

    with {:ok, within} <- within,
         :ok <- check_principal(dir, pkind, pid, within, resource),
         :ok <- check_custom_role(dir, role, within) do
      dir = revoke(dir, principal, resource)

      {:ok,
       %{dir | grants: dir.grants ++ [%{principal: principal, resource: resource, role: role}]}}
    end
  end

  defp check_principal(dir, :user, user, within, resource) do
    with {:ok, _} <- fetch_user(dir, user),
         :ok <- check_can_touch(dir, within, user) do
      case resource do
        {:org, org} ->
          check(org_member?(dir, org, user), "org-wide grants to a user require org membership")

        _ ->
          :ok
      end
    end
  end

  defp check_principal(dir, :team, team, within, _resource) do
    with {:ok, t} <- fetch(dir.teams, team, "team") do
      check(within?(dir, within, t.org), "a team can only be granted access within its own org")
    end
  end

  defp check_custom_role(dir, {:custom, id}, within) do
    with {:ok, c} <- fetch(dir.custom_roles, id, "custom role") do
      check(
        within?(dir, within, c.org),
        "a custom role can only be used within the org that defines it"
      )
    end
  end

  defp check_custom_role(_dir, _builtin, _within), do: :ok

  def revoke(dir, principal, resource) do
    %{
      dir
      | grants: Enum.reject(dir.grants, &(&1.principal == principal and &1.resource == resource))
    }
  end

  @doc "Blocks a user from everything beneath `blocker`, dropping their grants there."
  def block(dir, blocker, user) do
    with {:ok, _} <- fetch(dir.accounts, blocker, "account"),
         {:ok, _} <- fetch_user(dir, user),
         :ok <- check(blocker != user, "can't block yourself"),
         :ok <-
           check(
             org_role(dir, blocker, user) == nil,
             "remove them from the org before blocking them"
           ) do
      dir = %{dir | blocks: MapSet.put(dir.blocks, {blocker, user})}
      {:ok, drop_user_grants_within(dir, user, MapSet.new(subtree(dir, blocker)))}
    end
  end

  def unblock(dir, blocker, user), do: %{dir | blocks: MapSet.delete(dir.blocks, {blocker, user})}

  defp blocked_within?(dir, account, user) do
    Enum.any?(ancestors(dir, account), &({&1.id, user} in dir.blocks))
  end

  # Gates adding a user beneath `account`: not blocked, and on the right side
  # of any managed-enterprise boundary.
  defp check_can_touch(dir, account, user) do
    with :ok <- check(not blocked_within?(dir, account, user), "user #{user} is blocked here") do
      check_enterprise_boundary(dir, account, user)
    end
  end

  defp check_enterprise_boundary(dir, account, user) do
    home = enterprise_of(dir, user)
    here = enterprise_of(dir, account)

    with :ok <-
           check(
             home == nil or home == here,
             "managed users can't join or collaborate outside their enterprise"
           ) do
      check(
        here == nil or dir.enterprises[here].shortcode == nil or home == here,
        "a managed enterprise only admits its own managed users"
      )
    end
  end

  defp grant_owner(_dir, %{resource: {:org, o}}), do: o
  defp grant_owner(dir, %{resource: {:repo, r}}), do: dir.repos[r].owner

  defp drop_user_grants_within(dir, user, accounts) do
    keep = &(not (&1.principal == {:user, user} and grant_owner(dir, &1) in accounts))
    %{dir | grants: Enum.filter(dir.grants, keep)}
  end

  # Every user with a membership, team seat or grant beneath `org`.
  defp users_involved_in(dir, org) do
    subtree = MapSet.new(subtree(dir, org))
    members = for o <- subtree, {u, _} <- Map.get(dir.org_members, o, %{}), do: u

    granted =
      for %{principal: {:user, u}} = g <- dir.grants, grant_owner(dir, g) in subtree, do: u

    MapSet.new(members ++ granted)
  end

  # ---- paths ------------------------------------------------------------

  @doc "The account itself, then each parent org up to the root."
  def ancestors(dir, id) do
    Stream.unfold(dir.accounts[id], fn
      nil -> nil
      a -> {a, dir.accounts[parent(a)]}
    end)
    |> Enum.to_list()
  end

  defp within?(dir, account, ancestor),
    do: Enum.any?(ancestors(dir, account), &(&1.id == ancestor))

  defp subtree(dir, account),
    do: for(id <- Map.keys(dir.accounts), within?(dir, id, account), do: id)

  @doc "`a/b/c` for a sub-org, `alice` for a user."
  def path(dir, account) do
    case ancestors(dir, account) do
      [] -> nil
      chain -> chain |> Enum.reverse() |> Enum.map_join("/", & &1.slug)
    end
  end

  def repo_path(dir, repo) do
    with %{} = r <- dir.repos[repo], owner when owner != nil <- path(dir, r.owner) do
      "#{owner}/#{r.slug}"
    end
  end

  @doc "Resolves an account path, case-insensitively."
  def resolve(dir, path) do
    Enum.reduce_while(String.split(path, "/"), nil, fn seg, parent ->
      case Enum.find(accounts(dir), &(parent(&1) == parent and eq_ci?(&1.slug, seg))) do
        nil -> {:halt, :none}
        a -> {:cont, a.id}
      end
    end)
    |> case do
      :none -> nil
      id -> id
    end
  end

  @doc "Resolves `owner/path/repo`, case-insensitively."
  def resolve_repo(dir, path) do
    with {owners, [slug]} when owners != [] <- path |> String.split("/") |> Enum.split(-1),
         owner when owner != nil <- resolve(dir, Enum.join(owners, "/")),
         %{id: id} <- Enum.find(repos(dir), &(&1.owner == owner and eq_ci?(&1.slug, slug))) do
      id
    else
      _ -> nil
    end
  end

  # ---- access -----------------------------------------------------------

  @doc """
  What `user` (nil = anonymous) can do to `repo`: `%{role: role | nil,
  permissions: MapSet}`. Starts from the visibility floor; a blocked user,
  or a managed user outside their enterprise, stops there. Otherwise the max
  of: owning the repo or owning an org above it (admin), the base role of
  each org above it they're a member of, and every grant to them or their
  teams on the repo or an org above it.
  """
  def effective_access(dir, user, repo_id) do
    case dir.repos[repo_id] do
      nil -> %{role: nil, permissions: MapSet.new()}
      r -> access(dir, user, r)
    end
  end

  def effective_role(dir, user, repo), do: effective_access(dir, user, repo).role

  defp access(dir, user, r) do
    enterprise = enterprise_of(dir, r.owner)

    floor =
      case r.visibility do
        :public ->
          :read

        :internal ->
          if user && (enterprise == nil or enterprise_member?(dir, enterprise, user)), do: :read

        :private ->
          nil
      end

    acc = %{role: floor, permissions: MapSet.new()}
    home = user && enterprise_of(dir, user)

    cond do
      user == nil -> acc
      blocked_within?(dir, r.owner, user) or (home != nil and home != enterprise) -> acc
      r.owner == user or org_role(dir, r.owner, user) == :owner -> %{acc | role: :admin}
      true -> acc |> add_base_roles(dir, user, r) |> add_grants(dir, user, r)
    end
  end

  defp add_base_roles(acc, dir, user, r) do
    for %{kind: :org, base_role: base} = a <- ancestors(dir, r.owner),
        base,
        org_member?(dir, a.id, user),
        reduce: acc do
      acc -> %{acc | role: max_role(acc.role, base)}
    end
  end

  defp add_grants(acc, dir, user, r) do
    teams = teams_of(dir, user)

    for g <- dir.grants,
        holds?(g.principal, user, teams),
        covers?(dir, g.resource, r),
        reduce: acc do
      acc ->
        case g.role do
          {:custom, id} ->
            c = dir.custom_roles[id]

            %{
              acc
              | role: max_role(acc.role, c.base),
                permissions: MapSet.union(acc.permissions, c.permissions)
            }

          role ->
            %{acc | role: max_role(acc.role, role)}
        end
    end
  end

  defp holds?({:user, id}, user, _teams), do: id == user
  defp holds?({:team, id}, _user, teams), do: id in teams

  defp covers?(_dir, {:repo, id}, r), do: id == r.id
  defp covers?(dir, {:org, id}, r), do: within?(dir, r.owner, id)
end
